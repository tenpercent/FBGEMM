/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree.
 */
#include <ATen/ATen.h>
#include <ATen/Dispatch.h>
#include <ATen/cuda/CUDAContext.h>
#include <ATen/cuda/Exceptions.h>
#include <c10/cuda/CUDAGuard.h>
#include <torch/csrc/autograd/custom_function.h>
#include <torch/library.h>

// clang-format off
#include "fbgemm_gpu/cub_namespace_prefix.cuh"
#include "cub/device/device_scan.cuh"
#include "fbgemm_gpu/cub_namespace_postfix.cuh"
// clang-format on

#include "fbgemm_gpu/fbgemm_cuda_utils.cuh"
#include "fbgemm_gpu/sparse_ops_utils.h"

using Tensor = at::Tensor;

namespace fbgemm_gpu {

namespace {

/**
 * Ref. http://tensor-compiler.org/kjolstad-oopsla17-tensor-compiler.pdf
 * @param offset the input value points to the offset in the first jagged dim
 *               and output is the final offset to access the value tensor.
 *               It would've been better if we return a pair including this
 *               offset but CUDA doesn't seem to have comprehensive support
 *               on std::pair like std::tie.
 * @returns true if the flattend jagged idx points to zero'ed (masked out)
 *               portion of the jagged tensor
 */
template <int NUM_JAGGED_DIM, typename index_t>
DEVICE_INLINE bool walk_down_tensor_storage_tree_(
    int& offset,
    const int flattened_jagged_idx,
    const int64_t* jagged_dims,
    const std::array<index_t*, NUM_JAGGED_DIM>& x_offsets) {
  // compute coorindates
  int jagged_coords[NUM_JAGGED_DIM];
  int j_temp = flattened_jagged_idx;
#pragma unroll
  for (int d = NUM_JAGGED_DIM - 1; d >= 0; --d) {
    const int jagged_size = jagged_dims[d];
    jagged_coords[d] = j_temp % jagged_size;
    j_temp /= jagged_size;
  }

  // walk down the tree
  bool is_zero = false;
#pragma unroll
  for (int d = 0; d < NUM_JAGGED_DIM; ++d) {
    const int begin = x_offsets[d][offset];
    const int end = x_offsets[d][offset + 1];
    if (jagged_coords[d] >= end - begin) {
      is_zero = true;
      break;
    }
    offset = begin + jagged_coords[d];
  }
  return is_zero;
}

// output = f(x, y) where x is jagged, y is dense, and output is dense.
// A generic elementwise operation between a jagged tensor and a dense tensor
// This kernel assumes jagged dims are clustered together, preceded by outer
// dense dimensions and followed by inner dense dimensions.
// The outer/inner dense dimensions, and jagged dimensions in between are
// assumed to be folded so physically the dense tensor is 3D and the value of
// jagged tensor is 2D.
// To support arbitrary number of jagged dimensions, we pass a vector of
// pointers to offset tensors (this is ugly and probably we can use nested
// tensor here).
// This kernel parallelizes the (folded) inner dense dimension across
// blockDim.x so the inner dense dimension should be similar to or bigger than
// warp size.
// We rely on compiler unrolling the compiler time constant NUM_JAGGED_DIM.
template <int NUM_JAGGED_DIM, typename index_t, typename scalar_t, typename F>
__global__
__launch_bounds__(kMaxThreads) void jagged_dense_elementwise_dense_output_kernel_(
    const at::PackedTensorAccessor32<scalar_t, 2, at::RestrictPtrTraits>
        x_values,
    const std::array<index_t*, NUM_JAGGED_DIM> x_offsets,
    const at::PackedTensorAccessor32<scalar_t, 3, at::RestrictPtrTraits> y,
    at::PackedTensorAccessor32<scalar_t, 3, at::RestrictPtrTraits> output,
    const int64_t* jagged_dims,
    F f,
    const scalar_t padding_value) {
  const int outer_dense_size = y.size(0);
  const int jagged_folded_size = y.size(1);
  const int inner_dense_size = y.size(2);

  const int outer_begin = blockIdx.x * blockDim.y + threadIdx.y;
  const int outer_stride = gridDim.x * blockDim.y;
  for (int outer = outer_begin; outer < outer_dense_size * jagged_folded_size;
       outer += outer_stride) {
    const int oidx = outer / jagged_folded_size;
    const int jidx = outer % jagged_folded_size;

    int offset = oidx;
    const bool is_zero = walk_down_tensor_storage_tree_<NUM_JAGGED_DIM>(
        offset, jidx, jagged_dims, x_offsets);

    if (is_zero) {
      for (int iidx = threadIdx.x; iidx < inner_dense_size;
           iidx += blockDim.x) {
        output[oidx][jidx][iidx] = f(padding_value, y[oidx][jidx][iidx]);
      }
    } else {
      for (int iidx = threadIdx.x; iidx < inner_dense_size;
           iidx += blockDim.x) {
        output[oidx][jidx][iidx] =
            f(x_values[offset][iidx], y[oidx][jidx][iidx]);
      }
    }
  }
}

std::tuple<dim3, dim3, Tensor> check_shape_and_partition_(
    const Tensor& values,
    const std::vector<Tensor>& offsets,
    const Tensor& dense_tensor) {
  const int outer_dense_size = dense_tensor.size(0);
  TORCH_CHECK(
      outer_dense_size == offsets[0].numel() - 1,
      "outer_dense_size, ",
      outer_dense_size,
      " != offsets[0].numel() - 1, ",
      offsets[0].numel() - 1);
  const int inner_dense_size = dense_tensor.size(-1);
  TORCH_CHECK(
      inner_dense_size == values.size(-1),
      "inner_dense_size, ",
      inner_dense_size,
      " != values.size(-1), ",
      values.size(-1));
  const int jagged_folded_size =
      dense_tensor.numel() / (outer_dense_size * inner_dense_size);

  const int threads_x =
      inner_dense_size >= kWarpSize / 2 ? kWarpSize : inner_dense_size;
  const int threads_y = kMaxThreads / kWarpSize;
  const dim3 blocks(
      div_round_up(outer_dense_size * jagged_folded_size, threads_y));

  const int num_jagged_dim = dense_tensor.dim() - 2;
  Tensor jagged_dims_tensor = at::empty(
      {num_jagged_dim},
      at::TensorOptions().dtype(at::kLong).pinned_memory(true));
  memcpy(
      jagged_dims_tensor.data_ptr<int64_t>(),
      dense_tensor.sizes().data() + 1,
      num_jagged_dim * sizeof(int64_t));
  jagged_dims_tensor =
      jagged_dims_tensor.to(offsets[0].device(), /*non_blocking=*/true);

  return {dim3(threads_x, threads_y), blocks, jagged_dims_tensor};
}

template <typename scalar_t, typename F>
void jagged_dense_elementwise_dense_output_(
    const Tensor& x_values,
    const std::vector<Tensor>& x_offsets,
    const Tensor& y,
    const Tensor& output,
    F f,
    const scalar_t padding_value = static_cast<scalar_t>(0)) {
  TENSOR_ON_CUDA_GPU(x_values);
  for (auto& x_offset : x_offsets) {
    TENSOR_ON_CUDA_GPU(x_offset);
  }

  const int num_jagged_dim = y.dim() - 2;
  TORCH_CHECK(
      x_offsets.size() == static_cast<size_t>(num_jagged_dim),
      "x_offsets.size(), ",
      x_offsets.size(),
      " != num_jagged_dim ",
      num_jagged_dim);

  if (y.numel() == 0) {
    return;
  }

  dim3 threads, blocks;
  Tensor jagged_dims_tensor;
  std::tie(threads, blocks, jagged_dims_tensor) =
      check_shape_and_partition_(x_values, x_offsets, y);

  // Canonicalize y and output to 3D, collapsing jagged dimensions.
  const Tensor y_reshaped = y.view({y.size(0), -1, y.size(-1)});
  Tensor output_reshaped = output.view(y_reshaped.sizes());

#define INVOKE_KERNEL_WITH_DIM(NUM_JAGGED_DIM)                                \
  {                                                                           \
    Tensor x_offsets_contig[num_jagged_dim];                                  \
    std::array<index_t*, NUM_JAGGED_DIM> x_offset_ptrs;                       \
    for (int d = 0; d < num_jagged_dim; ++d) {                                \
      x_offsets_contig[d] = x_offsets[d].contiguous();                        \
      x_offset_ptrs[d] = x_offsets_contig[d].template data_ptr<index_t>();    \
    }                                                                         \
    jagged_dense_elementwise_dense_output_kernel_<NUM_JAGGED_DIM, index_t>    \
        <<<blocks, threads, 0, at::cuda::getCurrentCUDAStream()>>>(           \
            x_values.packed_accessor32<scalar_t, 2, at::RestrictPtrTraits>(), \
            x_offset_ptrs,                                                    \
            y_reshaped                                                        \
                .packed_accessor32<scalar_t, 3, at::RestrictPtrTraits>(),     \
            output_reshaped                                                   \
                .packed_accessor32<scalar_t, 3, at::RestrictPtrTraits>(),     \
            jagged_dims_tensor.data_ptr<int64_t>(),                           \
            f,                                                                \
            padding_value);                                                   \
  }

  JAGGED_TENSOR_DISPATCH_DIMS();
  C10_CUDA_KERNEL_LAUNCH_CHECK();

#undef INVOKE_KERNEL_WITH_DIM
}

template <typename scalar_t, typename F>
Tensor jagged_dense_elementwise_dense_output_(
    const Tensor& x_values,
    const std::vector<Tensor>& x_offsets,
    const Tensor& y,
    F f,
    const scalar_t padding_value = static_cast<scalar_t>(0)) {
  Tensor output = at::empty_like(y);
  jagged_dense_elementwise_dense_output_(
      x_values, x_offsets, y, output, f, padding_value);
  return output;
}

template <int NUM_JAGGED_DIM, typename index_t, typename scalar_t, typename F>
__global__
__launch_bounds__(kMaxThreads) void jagged_dense_elementwise_jagged_output_kernel_(
    const at::PackedTensorAccessor32<scalar_t, 2, at::RestrictPtrTraits>
        x_values,
    const std::array<index_t*, NUM_JAGGED_DIM> x_offsets,
    const at::PackedTensorAccessor32<scalar_t, 3, at::RestrictPtrTraits> y,
    at::PackedTensorAccessor32<scalar_t, 2, at::RestrictPtrTraits>
        output_values,
    const int64_t* jagged_dims,
    F f) {
  const int outer_dense_size = y.size(0);
  const int jagged_folded_size = y.size(1);
  const int inner_dense_size = y.size(2);

  const int outer_begin = blockIdx.x * blockDim.y + threadIdx.y;
  const int outer_stride = gridDim.x * blockDim.y;
  for (int outer = outer_begin; outer < outer_dense_size * jagged_folded_size;
       outer += outer_stride) {
    const int oidx = outer / jagged_folded_size;
    const int jidx = outer % jagged_folded_size;

    int offset = oidx;
    const bool is_zero = walk_down_tensor_storage_tree_<NUM_JAGGED_DIM>(
        offset, jidx, jagged_dims, x_offsets);

    if (!is_zero) {
      for (int iidx = threadIdx.x; iidx < inner_dense_size;
           iidx += blockDim.x) {
        output_values[offset][iidx] =
            f(x_values[offset][iidx], y[oidx][jidx][iidx]);
      }
    }
  }
}

template <typename scalar_t, typename F>
void jagged_dense_elementwise_jagged_output_(
    const Tensor& x_values,
    const std::vector<Tensor>& x_offsets,
    const Tensor& y,
    const Tensor& output_values,
    F f) {
  TENSOR_ON_CUDA_GPU(x_values);
  for (auto& x_offset : x_offsets) {
    TENSOR_ON_CUDA_GPU(x_offset);
  }

  const int num_jagged_dim = y.dim() - 2;
  TORCH_CHECK(
      x_offsets.size() == static_cast<size_t>(num_jagged_dim),
      "x_offsets.size(), ",
      x_offsets.size(),
      " != num_jagged_dim, ",
      num_jagged_dim);

  if (y.numel() == 0) {
    return;
  }

  dim3 threads, blocks;
  Tensor jagged_dims_tensor;
  std::tie(threads, blocks, jagged_dims_tensor) =
      check_shape_and_partition_(x_values, x_offsets, y);

  // Canonicalize y to 3D, collapsing jagged dimensions.
  const Tensor y_reshaped = y.view({y.size(0), -1, y.size(-1)});

#define INVOKE_KERNEL_WITH_DIM(NUM_JAGGED_DIM)                                \
  {                                                                           \
    Tensor x_offsets_contig[num_jagged_dim];                                  \
    std::array<index_t*, NUM_JAGGED_DIM> x_offset_ptrs;                       \
    for (int d = 0; d < num_jagged_dim; ++d) {                                \
      x_offsets_contig[d] = x_offsets[d].contiguous();                        \
      x_offset_ptrs[d] = x_offsets_contig[d].template data_ptr<index_t>();    \
    }                                                                         \
    jagged_dense_elementwise_jagged_output_kernel_<NUM_JAGGED_DIM, index_t>   \
        <<<blocks, threads, 0, at::cuda::getCurrentCUDAStream()>>>(           \
            x_values.packed_accessor32<scalar_t, 2, at::RestrictPtrTraits>(), \
            x_offset_ptrs,                                                    \
            y_reshaped                                                        \
                .packed_accessor32<scalar_t, 3, at::RestrictPtrTraits>(),     \
            output_values                                                     \
                .packed_accessor32<scalar_t, 2, at::RestrictPtrTraits>(),     \
            jagged_dims_tensor.data_ptr<int64_t>(),                           \
            f);                                                               \
  }

  JAGGED_TENSOR_DISPATCH_DIMS();
  C10_CUDA_KERNEL_LAUNCH_CHECK();

#undef INVOKE_KERNEL_WITH_DIM
}

class JaggedToPaddedDenseGPUOp
    : public torch::autograd::Function<JaggedToPaddedDenseGPUOp> {
 public:
  static torch::autograd::variable_list forward(
      torch::autograd::AutogradContext* ctx,
      const Tensor& values,
      const std::vector<Tensor>& offsets,
      const std::vector<int64_t>& max_lengths,
      const double padding_value) {
    ctx->save_for_backward(offsets);
    ctx->saved_data["total_L"] = values.size(0);

    const size_t num_jagged_dim = offsets.size();
    TORCH_CHECK(
        max_lengths.size() == num_jagged_dim,
        "max_lengths.size(), ",
        max_lengths.size(),
        " != num_jagged_dim, ",
        num_jagged_dim);
    at::cuda::OptionalCUDAGuard device_guard;
    device_guard.set_index(values.get_device());

    const Tensor values_canonicalized = values.view(
        {values.size(0),
         std::accumulate(
             values.sizes().begin() + 1,
             values.sizes().end(),
             1,
             std::multiplies<size_t>())});
    at::DimVector padded_values_shape({offsets[0].size(0) - 1});
    padded_values_shape.insert(
        padded_values_shape.end(), max_lengths.begin(), max_lengths.end());
    if (values.dim() > 1) {
      padded_values_shape.push_back(values.size(-1));
    }
    Tensor padded_values = at::empty(padded_values_shape, values.options());
    Tensor padded_values_view =
        values.dim() == 1 ? padded_values.unsqueeze(-1) : padded_values;

    AT_DISPATCH_ALL_TYPES_AND(
        at::ScalarType::Half,
        values.scalar_type(),
        "jagged_to_padded_dense",
        [&] {
          jagged_dense_elementwise_dense_output_<scalar_t>(
              values_canonicalized,
              offsets,
              padded_values_view, // dummy not used in the lambda function
              padded_values_view,
              [] __device__(scalar_t x, scalar_t /*unused*/) -> scalar_t {
                return x;
              },
              static_cast<scalar_t>(padding_value));
        });

    return {padded_values};
  }

  static torch::autograd::variable_list backward(
      torch::autograd::AutogradContext* ctx,
      torch::autograd::variable_list grad_outputs) {
    auto offsets = ctx->get_saved_variables();
    int32_t total_L = ctx->saved_data["total_L"].toInt();
    TORCH_CHECK(grad_outputs.size() == 1);

    TORCH_CHECK(total_L >= 0);
    auto grad_padded_values = grad_outputs[0];
    at::cuda::OptionalCUDAGuard device_guard;
    device_guard.set_index(grad_padded_values.get_device());

    int32_t D = grad_padded_values.size(-1);
    // Initialize with zeros so output will be zero for the portion truncated
    // in forward.
    auto grad_values = at::zeros({total_L, D}, grad_padded_values.options());

    AT_DISPATCH_FLOATING_TYPES_AND_HALF(
        grad_padded_values.scalar_type(),
        "jagged_2d_to_dense_backward_kernel",
        [&] {
          jagged_dense_elementwise_jagged_output_<scalar_t>(
              grad_values, // dummy not used in the lambda function
              {offsets},
              grad_padded_values,
              grad_values,
              [] __device__(scalar_t /*unused*/, scalar_t y) -> scalar_t {
                return y;
              });
        });

    return {
        grad_values,
        torch::autograd::Variable(), // offsets
        torch::autograd::Variable(), // max_lengths
        torch::autograd::Variable(), // padding_value
    };
  }
};

Tensor jagged_to_padded_dense(
    const Tensor& values,
    const std::vector<Tensor>& offsets,
    const std::vector<int64_t>& max_lengths,
    const double padding_value) {
  return JaggedToPaddedDenseGPUOp::apply(
      values, offsets, max_lengths, padding_value)[0];
}

Tensor
jagged_2d_to_dense(Tensor values, Tensor offsets, int64_t max_sequence_length) {
  return jagged_to_padded_dense(
      values, {offsets}, {max_sequence_length}, /*padding_value=*/0);
}

class JaggedDenseAddGPUOp
    : public torch::autograd::Function<JaggedDenseAddGPUOp> {
 public:
  static torch::autograd::variable_list forward(
      torch::autograd::AutogradContext* ctx,
      const Tensor& x_values,
      const std::vector<Tensor>& x_offsets,
      const Tensor& y) {
    ctx->save_for_backward(x_offsets);
    ctx->saved_data["x_values_shape"] = x_values.sizes();

    at::cuda::OptionalCUDAGuard device_guard;
    device_guard.set_index(x_values.get_device());

    Tensor output;
    AT_DISPATCH_FLOATING_TYPES_AND_HALF(
        x_values.scalar_type(), "jagged_dense_add_forward", [&] {
          output = jagged_dense_elementwise_dense_output_<scalar_t>(
              x_values,
              x_offsets,
              y,
              [] __device__(scalar_t x, scalar_t y) -> scalar_t {
                return x + y;
              });
        });

    return {output};
  }

  static torch::autograd::variable_list backward(
      torch::autograd::AutogradContext* ctx,
      torch::autograd::variable_list grad_outputs) {
    auto offsets = ctx->get_saved_variables();
    auto x_values_shape = ctx->saved_data["x_values_shape"].toIntVector();
    TORCH_CHECK(grad_outputs.size() == 1);

    at::cuda::OptionalCUDAGuard device_guard;
    device_guard.set_index(grad_outputs[0].get_device());

    Tensor x_values_grad = at::zeros(x_values_shape, grad_outputs[0].options());

    AT_DISPATCH_FLOATING_TYPES_AND_HALF(
        x_values_grad.scalar_type(), "jagged_dense_add_backward", [&] {
          jagged_dense_elementwise_jagged_output_<scalar_t>(
              x_values_grad, // dummy not used in the lambda function
              offsets,
              grad_outputs[0],
              x_values_grad,
              [] __device__(scalar_t /*unused*/, scalar_t y) -> scalar_t {
                return y;
              });
        });

    return {
        x_values_grad,
        torch::autograd::Variable(), // x_offsets
        grad_outputs[0]};
  }
};

// output = x + y where x is jagged, y and output are dense
Tensor jagged_dense_elementwise_add(
    const Tensor& x_values,
    const std::vector<Tensor>& x_offsets,
    const Tensor& y) {
  return JaggedDenseAddGPUOp::apply(x_values, x_offsets, y)[0];
}

class DenseToJaggedGPUOp
    : public torch::autograd::Function<DenseToJaggedGPUOp> {
 public:
  static torch::autograd::variable_list forward(
      torch::autograd::AutogradContext* ctx,
      const Tensor& dense,
      const std::vector<Tensor>& offsets,
      const c10::optional<int64_t>& total_L) {
    ctx->save_for_backward(offsets);
    ctx->saved_data["dense_shape"] = dense.sizes();

    // D is the embedding dimension
    auto D = dense.size(-1);

    // If total_L is not given then compute it
    int64_t total_L_computed;
    if (total_L.has_value()) {
      total_L_computed = total_L.value();
    } else {
      total_L_computed = (int64_t)offsets.back().max().item<int64_t>();
    }
    auto values = at::empty({total_L_computed, D}, dense.options());
    auto output = at::zeros({total_L_computed, D}, dense.options());

    at::cuda::OptionalCUDAGuard device_guard;
    device_guard.set_index(dense.get_device());

    AT_DISPATCH_FLOATING_TYPES_AND_HALF(
        values.scalar_type(), "jagged_dense_add_forward", [&] {
          jagged_dense_elementwise_jagged_output_<scalar_t>(
              values,
              offsets,
              dense,
              output,
              [] __device__(scalar_t /*unused*/, scalar_t y) -> scalar_t {
                return y;
              });
        });

    return {output};
  }

  static torch::autograd::variable_list backward(
      torch::autograd::AutogradContext* ctx,
      torch::autograd::variable_list grad_outputs) {
    auto offsets = ctx->get_saved_variables();
    auto dense_shape = ctx->saved_data["dense_shape"].toIntVector();
    TORCH_CHECK(grad_outputs.size() == 1);

    at::cuda::OptionalCUDAGuard device_guard;
    device_guard.set_index(grad_outputs[0].get_device());

    Tensor dense_values_grad = jagged_to_padded_dense(
        grad_outputs[0],
        offsets,
        std::vector<int64_t>(dense_shape.begin() + 1, dense_shape.end() - 1),
        /*padding_value=*/0);
    TORCH_CHECK(dense_values_grad.sizes() == dense_shape);

    return {
        dense_values_grad,
        torch::autograd::Variable(), // offsets
        torch::autograd::Variable()}; // total_L
  }
};

std::tuple<Tensor, std::vector<Tensor>> dense_to_jagged(
    const Tensor& dense,
    const std::vector<Tensor>& offsets,
    const c10::optional<int64_t>& total_L) {
  return {DenseToJaggedGPUOp::apply(dense, offsets, total_L)[0], offsets};
}

// Unlike JaggedDenseAddGPUOp that treats "zeros" as zeros so adding with
// a dense tensor results in a dense tensor, this operator treats "zeros" as
// undefined so resulting a jagged tensor.
class JaggedDenseAddJaggedOutputGPUOp
    : public torch::autograd::Function<JaggedDenseAddJaggedOutputGPUOp> {
 public:
  static torch::autograd::variable_list forward(
      torch::autograd::AutogradContext* ctx,
      const Tensor& x_values,
      const std::vector<Tensor>& x_offsets,
      const Tensor& y) {
    ctx->save_for_backward(x_offsets);
    ctx->saved_data["y_shape"] = y.sizes();

    at::cuda::OptionalCUDAGuard device_guard;
    device_guard.set_index(x_values.get_device());

    // Initialize with jagged input so output will have the same value as the
    // jagged tensor if there's no corresponding value in the dense tensor.
    Tensor output = x_values.clone();

    AT_DISPATCH_FLOATING_TYPES_AND_HALF(
        x_values.scalar_type(), "jagged_dense_add_forward", [&] {
          jagged_dense_elementwise_jagged_output_<scalar_t>(
              x_values,
              x_offsets,
              y,
              output,
              [] __device__(scalar_t x, scalar_t y) -> scalar_t {
                return x + y;
              });
        });

    return {output};
  }

  static torch::autograd::variable_list backward(
      torch::autograd::AutogradContext* ctx,
      torch::autograd::variable_list grad_outputs) {
    auto offsets = ctx->get_saved_variables();
    auto y_shape = ctx->saved_data["y_shape"].toIntVector();
    TORCH_CHECK(grad_outputs.size() == 1);

    at::cuda::OptionalCUDAGuard device_guard;
    device_guard.set_index(grad_outputs[0].get_device());

    Tensor y_values_grad = jagged_to_padded_dense(
        grad_outputs[0],
        offsets,
        std::vector<int64_t>(y_shape.begin() + 1, y_shape.end() - 1),
        /*padding_value=*/0);
    TORCH_CHECK(y_values_grad.sizes() == y_shape);

    return {
        grad_outputs[0],
        torch::autograd::Variable(), // x_offsets
        y_values_grad};
  }
};

// output = x + y where x is jagged, y is dense, and output is jagged
std::tuple<Tensor, std::vector<Tensor>>
jagged_dense_elementwise_add_jagged_output(
    const Tensor& x_values,
    const std::vector<Tensor>& x_offsets,
    const Tensor& y) {
  return {
      JaggedDenseAddJaggedOutputGPUOp::apply(x_values, x_offsets, y)[0],
      x_offsets};
}

/**
 * output = f(x, y) where x and y are jagged (and share x_offsets), and output
 * is dense.
 *
 * @param padding_value padding_value for the output, not for inputs
 */
template <int NUM_JAGGED_DIM, typename index_t, typename scalar_t, typename F>
__global__
__launch_bounds__(kMaxThreads) void jagged_jagged_elementwise_dense_output_kernel_(
    const at::PackedTensorAccessor32<scalar_t, 2, at::RestrictPtrTraits>
        x_values,
    const std::array<index_t*, NUM_JAGGED_DIM> x_offsets,
    const at::PackedTensorAccessor32<scalar_t, 2, at::RestrictPtrTraits>
        y_values,
    at::PackedTensorAccessor32<scalar_t, 3, at::RestrictPtrTraits> output,
    const int64_t* jagged_dims,
    F f,
    const scalar_t padding_value) {
  const int outer_dense_size = output.size(0);
  const int jagged_folded_size = output.size(1);
  const int inner_dense_size = output.size(2);

  const int outer_begin = blockIdx.x * blockDim.y + threadIdx.y;
  const int outer_stride = gridDim.x * blockDim.y;
  for (int outer = outer_begin; outer < outer_dense_size * jagged_folded_size;
       outer += outer_stride) {
    const int oidx = outer / jagged_folded_size;
    const int jidx = outer % jagged_folded_size;

    int offset = oidx;
    const bool is_zero = walk_down_tensor_storage_tree_<NUM_JAGGED_DIM>(
        offset, jidx, jagged_dims, x_offsets);

    if (is_zero) {
      for (int iidx = threadIdx.x; iidx < inner_dense_size;
           iidx += blockDim.x) {
        output[oidx][jidx][iidx] = padding_value;
      }
    } else {
      for (int iidx = threadIdx.x; iidx < inner_dense_size;
           iidx += blockDim.x) {
        output[oidx][jidx][iidx] =
            f(x_values[offset][iidx], y_values[offset][iidx]);
      }
    }
  }
}

template <typename scalar_t, typename F>
void jagged_jagged_elementwise_dense_output_(
    const Tensor& x_values,
    const std::vector<Tensor>& x_offsets,
    const Tensor& y_values,
    const Tensor& output,
    F f,
    const scalar_t padding_value = static_cast<scalar_t>(0)) {
  TENSOR_ON_CUDA_GPU(x_values);
  for (auto& x_offset : x_offsets) {
    TENSOR_ON_CUDA_GPU(x_offset);
  }

  const int num_jagged_dim = output.dim() - 2;
  TORCH_CHECK(
      x_offsets.size() == static_cast<size_t>(num_jagged_dim),
      "x_offsets.size(), ",
      x_offsets.size(),
      " != num_jagged_dim, ",
      num_jagged_dim);

  if (output.numel() == 0) {
    return;
  }

  dim3 threads, blocks;
  Tensor jagged_dims_tensor;
  std::tie(threads, blocks, jagged_dims_tensor) =
      check_shape_and_partition_(x_values, x_offsets, output);

  // Canonicalize output to 3D, collapsing jagged dimensions.
  Tensor output_reshaped = output.view({output.size(0), -1, output.size(-1)});

#define INVOKE_KERNEL_WITH_DIM(NUM_JAGGED_DIM)                                \
  {                                                                           \
    Tensor x_offsets_contig[num_jagged_dim];                                  \
    std::array<index_t*, NUM_JAGGED_DIM> x_offset_ptrs;                       \
    for (int d = 0; d < num_jagged_dim; ++d) {                                \
      x_offsets_contig[d] = x_offsets[d].contiguous();                        \
      x_offset_ptrs[d] = x_offsets_contig[d].template data_ptr<index_t>();    \
    }                                                                         \
    jagged_jagged_elementwise_dense_output_kernel_<NUM_JAGGED_DIM, index_t>   \
        <<<blocks, threads, 0, at::cuda::getCurrentCUDAStream()>>>(           \
            x_values.packed_accessor32<scalar_t, 2, at::RestrictPtrTraits>(), \
            x_offset_ptrs,                                                    \
            y_values.packed_accessor32<scalar_t, 2, at::RestrictPtrTraits>(), \
            output_reshaped                                                   \
                .packed_accessor32<scalar_t, 3, at::RestrictPtrTraits>(),     \
            jagged_dims_tensor.data_ptr<int64_t>(),                           \
            f,                                                                \
            padding_value);                                                   \
  }

  JAGGED_TENSOR_DISPATCH_DIMS();
  C10_CUDA_KERNEL_LAUNCH_CHECK();

#undef INVOKE_KERNEL_WITH_DIM
}

class JaggedDenseMulGPUOp
    : public torch::autograd::Function<JaggedDenseMulGPUOp> {
 public:
  static torch::autograd::variable_list forward(
      torch::autograd::AutogradContext* ctx,
      const Tensor& x_values,
      const std::vector<Tensor>& x_offsets,
      const Tensor& y) {
    std::vector<Tensor> tensors_to_save;
    tensors_to_save.push_back(x_values);
    tensors_to_save.insert(
        tensors_to_save.end(), x_offsets.begin(), x_offsets.end());
    tensors_to_save.push_back(y);
    ctx->save_for_backward(tensors_to_save);

    at::cuda::OptionalCUDAGuard device_guard;
    device_guard.set_index(x_values.get_device());

    // Initialize with zero so output will be zero if there's no corresponding
    // value in the dense tensor.
    Tensor output = at::zeros_like(x_values);
    AT_DISPATCH_FLOATING_TYPES_AND_HALF(
        x_values.scalar_type(), "jagged_scalars", [&] {
          jagged_dense_elementwise_jagged_output_<scalar_t>(
              x_values,
              x_offsets,
              y,
              output,
              [] __device__(scalar_t x, scalar_t y) -> scalar_t {
                return x * y;
              });
        });

    return {output};
  }

  static torch::autograd::variable_list backward(
      torch::autograd::AutogradContext* ctx,
      torch::autograd::variable_list grad_outputs) {
    const Tensor x_values = ctx->get_saved_variables().front();
    // Somehow, the following code generates a segfault during atomic
    // operations probably related to ref counting.
    // std::vector<Tensor> x_offsets(
    //    ctx->get_saved_variables().begin() + 1,
    //    ctx->get_saved_variables().end() - 1);
    std::vector<Tensor> x_offsets;
    for (int i = 1; i < ctx->get_saved_variables().size() - 1; ++i) {
      x_offsets.push_back(ctx->get_saved_variables()[i]);
    }
    Tensor y = ctx->get_saved_variables().back();
    TORCH_CHECK(grad_outputs.size() == 1);

    at::cuda::OptionalCUDAGuard device_guard;
    device_guard.set_index(grad_outputs[0].get_device());

    Tensor x_values_grad = at::zeros_like(grad_outputs[0]);
    Tensor y_grad = at::empty_like(y);

    AT_DISPATCH_FLOATING_TYPES_AND_HALF(
        x_values.scalar_type(), "jagged_scalars", [&] {
          jagged_dense_elementwise_jagged_output_<scalar_t>(
              grad_outputs[0],
              x_offsets,
              y,
              x_values_grad,
              [] __device__(scalar_t x, scalar_t y) -> scalar_t {
                return x * y;
              });

          jagged_jagged_elementwise_dense_output_<scalar_t>(
              grad_outputs[0],
              x_offsets,
              x_values,
              y_grad,
              [] __device__(scalar_t x, scalar_t y) -> scalar_t {
                return x * y;
              });
        });

    return {
        x_values_grad,
        torch::autograd::Variable(), // x_offsets
        y_grad};
  }
};

std::tuple<Tensor, std::vector<Tensor>> jagged_dense_elementwise_mul(
    const Tensor& x_values,
    const std::vector<Tensor>& x_offsets,
    const Tensor& y) {
  return {JaggedDenseMulGPUOp::apply(x_values, x_offsets, y)[0], x_offsets};
}

template <typename index_t, typename scalar_t>
__global__ __launch_bounds__(kMaxThreads) void dense_vec_jagged_2d_bmm(
    const at::PackedTensorAccessor32<scalar_t, 2> v,
    const at::PackedTensorAccessor32<scalar_t, 2> a_values,
    const at::PackedTensorAccessor32<index_t, 1> a_offsets,
    at::PackedTensorAccessor32<scalar_t, 2> output) {
  const int B = a_offsets.size(0) - 1;
  const int H = v.size(0) / B;
  const int max_L = v.size(1);
  const int D = output.size(1);

  const int b_h_begin = blockIdx.x * blockDim.y + threadIdx.y;
  const int b_h_step = gridDim.x * blockDim.y;
  for (int b_h = b_h_begin; b_h < B * H; b_h += b_h_step) {
    const int b = b_h / H;
    const int h = b_h % H;

    const int row_start = a_offsets[b];
    const int row_end = a_offsets[b + 1];
    const int length = std::min(row_end - row_start, max_L);
    if (length == 0) {
      for (int d = threadIdx.x; d < D; d += blockDim.x) {
        output[b_h][d] = 0;
      }
    } else {
      // TODO: use shared memory
      for (int d = threadIdx.x; d < D; d += blockDim.x) {
        at::acc_type<scalar_t, true> acc =
            v[b_h][0] * a_values[row_start][h * D + d];
        for (int l = 1; l < length; ++l) {
          acc += v[b_h][l] * a_values[row_start + l][h * D + d];
        }
        output[b_h][d] = acc;
      }
    }
  }
}

template <typename index_t, typename scalar_t>
__global__
__launch_bounds__(kMaxThreads) void dense_vec_jagged_2d_transposed_bmm(
    const at::PackedTensorAccessor32<scalar_t, 2> v,
    const at::PackedTensorAccessor32<scalar_t, 2> a_values,
    const at::PackedTensorAccessor32<index_t, 1> a_offsets,
    at::PackedTensorAccessor32<scalar_t, 2> output) {
  const int B = a_offsets.size(0) - 1;
  const int H = v.size(0) / B;
  const int max_L = output.size(1);
  const int D = v.size(1);

  const int b_h_begin = blockIdx.x * blockDim.y + threadIdx.y;
  const int b_h_step = gridDim.x * blockDim.y;
  for (int b_h = b_h_begin; b_h < B * H; b_h += b_h_step) {
    const int b = b_h / H;
    const int h = b_h % H;

    const int row_start = a_offsets[b];
    const int row_end = a_offsets[b + 1];
    const int length = std::min(row_end - row_start, max_L);
    if (D == 0) {
      for (int l = threadIdx.x; l < max_L; ++l) {
        output[b_h][l] = 0;
      }
    } else {
      int l;
      for (l = threadIdx.x; l < length; l += blockDim.x) {
        at::acc_type<scalar_t, true> acc =
            v[b_h][0] * a_values[row_start + l][h * D];
        for (int d = 1; d < D; ++d) {
          acc += v[b_h][d] * a_values[row_start + l][h * D + d];
        }
        output[b_h][l] = acc;
      }
      for (; l < max_L; l += blockDim.x) {
        output[b_h][l] = 0;
      }
    }
  }
}

template <typename index_t, typename scalar_t>
__global__ __launch_bounds__(kMaxThreads) void outer_prod_jagged_2d_output(
    const at::PackedTensorAccessor32<scalar_t, 2> x,
    const at::PackedTensorAccessor32<scalar_t, 2> y,
    const at::PackedTensorAccessor32<index_t, 1> offsets,
    at::PackedTensorAccessor32<scalar_t, 2> output_values) {
  const int B = offsets.size(0) - 1;
  const int H = x.size(0) / B;
  const int max_L = x.size(1);
  const int D = y.size(1);

  const int b_h_l_begin = blockIdx.x * blockDim.y + threadIdx.y;
  const int b_h_l_step = gridDim.x * blockDim.y;
  for (int b_h_l = b_h_l_begin; b_h_l < B * H * max_L; b_h_l += b_h_l_step) {
    const int b_h = b_h_l / max_L;
    const int b = b_h / H;
    const int h = b_h % H;
    const int l = b_h_l % max_L;

    const int row_start = offsets[b];
    const int row_end = offsets[b + 1];
    const int length = row_end - row_start;
    if (l < length) {
      for (int d = threadIdx.x; d < D; d += blockDim.x) {
        output_values[row_start + l][h * D + d] = x[b_h][l] * y[b_h][d];
      }
    }
  }
}

// batched dense vector x jagged 2D tensor multiplication
// dense vector [B H, N]
// jagged tensor [B, N, H D] where N is jagged
class BatchedDenseVecJagged2DMulGPUOp
    : public torch::autograd::Function<BatchedDenseVecJagged2DMulGPUOp> {
 public:
  static torch::autograd::variable_list forward(
      torch::autograd::AutogradContext* ctx,
      const Tensor& v,
      const Tensor& a_values,
      const Tensor& a_offsets) {
    ctx->save_for_backward({v, a_values, a_offsets});

    TENSOR_ON_CUDA_GPU(v);
    TENSOR_ON_CUDA_GPU(a_values);
    TENSOR_ON_CUDA_GPU(a_offsets);

    at::cuda::OptionalCUDAGuard device_guard;
    device_guard.set_index(v.get_device());

    const int B = a_offsets.numel() - 1;
    TORCH_CHECK(
        B == 0 || v.size(0) % B == 0,
        "B, ",
        B,
        " doesn't divide v.size(0), ",
        v.size(0));
    const int H = (B == 0) ? 1 : v.size(0) / B;
    const int D = a_values.size(-1) / H;
    const int max_L = v.size(-1);
    auto output = at::empty({B * H, D}, v.options());

    if (B > 0 && D > 0) {
      const int block_dim_x =
          std::min(div_round_up(D, kWarpSize) * kWarpSize, kMaxThreads);
      const int block_dim_y = kMaxThreads / block_dim_x;

      AT_DISPATCH_INDEX_TYPES(
          a_offsets.scalar_type(), "dense_vec_jagged_2d_bmm_kernel_1", [&] {
            AT_DISPATCH_FLOATING_TYPES_AND_HALF(
                a_values.scalar_type(),
                "dense_vec_jagged_2d_bmm_kernel_2",
                [&] {
                  dense_vec_jagged_2d_bmm<index_t, scalar_t>
                      <<<div_round_up(B * H, block_dim_y),
                         dim3(block_dim_x, block_dim_y),
                         0,
                         at::cuda::getCurrentCUDAStream()>>>(
                          v.packed_accessor32<scalar_t, 2>(),
                          a_values.packed_accessor32<scalar_t, 2>(),
                          a_offsets.packed_accessor32<index_t, 1>(),
                          output.packed_accessor32<scalar_t, 2>());
                  C10_CUDA_KERNEL_LAUNCH_CHECK();
                });
          });
    }

    return {output};
  }

  static torch::autograd::variable_list backward(
      torch::autograd::AutogradContext* ctx,
      torch::autograd::variable_list grad_outputs) {
    const auto saved = ctx->get_saved_variables();
    auto savedItr = std::begin(saved);
    const Tensor v = *savedItr++;
    const Tensor a_values = *savedItr++;
    const Tensor a_offsets = *savedItr++;
    TORCH_CHECK(grad_outputs.size() == 1);

    TENSOR_ON_CUDA_GPU(grad_outputs[0]);
    TENSOR_ON_CUDA_GPU(a_values);
    TENSOR_ON_CUDA_GPU(a_offsets);
    TENSOR_ON_CUDA_GPU(v);

    at::cuda::OptionalCUDAGuard device_guard;
    device_guard.set_index(grad_outputs[0].get_device());

    const int B = a_offsets.numel() - 1;
    const int D = grad_outputs[0].size(-1);

    Tensor a_values_grad = at::zeros_like(a_values);
    Tensor v_grad = at::empty_like(v);

    if (B > 0 && D > 0) {
      TORCH_CHECK(
          v.size(0) % B == 0,
          "B, ",
          B,
          " doesn't divide v.size(0), ",
          v.size(0));
      const int H = v.size(0) / B;
      const int max_L = v.size(-1);

      AT_DISPATCH_INDEX_TYPES(
          a_offsets.scalar_type(),
          "dense_vec_jagged_2d_bmm_baackward_kernel_1",
          [&] {
            AT_DISPATCH_FLOATING_TYPES_AND_HALF(
                grad_outputs[0].scalar_type(),
                "dense_vec_jagged_2d_bmm_baackward_kernel_2",
                [&] {
                  int block_dim_x = std::min(
                      div_round_up(max_L, kWarpSize) * kWarpSize, kMaxThreads);
                  int block_dim_y = kMaxThreads / block_dim_x;

                  dense_vec_jagged_2d_transposed_bmm<index_t, scalar_t>
                      <<<div_round_up(B * H, block_dim_y),
                         dim3(block_dim_x, block_dim_y),
                         0,
                         at::cuda::getCurrentCUDAStream()>>>(
                          grad_outputs[0].packed_accessor32<scalar_t, 2>(),
                          a_values.packed_accessor32<scalar_t, 2>(),
                          a_offsets.packed_accessor32<index_t, 1>(),
                          v_grad.packed_accessor32<scalar_t, 2>());
                  C10_CUDA_KERNEL_LAUNCH_CHECK();

                  block_dim_x = std::min(
                      div_round_up(D, kWarpSize) * kWarpSize, kMaxThreads);
                  block_dim_y = kMaxThreads / block_dim_x;

                  outer_prod_jagged_2d_output<index_t, scalar_t>
                      <<<div_round_up(B * H * max_L, block_dim_y),
                         dim3(block_dim_x, block_dim_y),
                         0,
                         at::cuda::getCurrentCUDAStream()>>>(
                          v.packed_accessor32<scalar_t, 2>(),
                          grad_outputs[0].packed_accessor32<scalar_t, 2>(),
                          a_offsets.packed_accessor32<index_t, 1>(),
                          a_values_grad.packed_accessor32<scalar_t, 2>());
                  C10_CUDA_KERNEL_LAUNCH_CHECK();
                });
          });
    } else {
      v_grad.zero_();
    }

    return {
        v_grad,
        a_values_grad,
        torch::autograd::Variable(), // a_offsets
    };
  }
};

Tensor batched_dense_vec_jagged_2d_mul(
    const Tensor& v,
    const Tensor& a_values,
    const Tensor& a_offsets) {
  return BatchedDenseVecJagged2DMulGPUOp::apply(v, a_values, a_offsets)[0];
}

} // namespace

Tensor jagged_1d_to_dense_gpu(
    Tensor values,
    Tensor offsets,
    int64_t max_L,
    int64_t padding_value) {
  TORCH_CHECK(values.dim() == 1);
  TORCH_CHECK(offsets.dim() == 1);
  TORCH_CHECK(max_L > 0);

  return jagged_to_padded_dense(values, {offsets}, {max_L}, padding_value);
}

// stacked ops
std::tuple<std::vector<Tensor>, std::vector<Tensor>>
stacked_jagged_2d_to_dense_forward_cuda(
    Tensor values,
    Tensor lengths,
    const std::vector<int64_t>& offset_per_key,
    const std::vector<int64_t>& max_lengths_per_key) {
  TORCH_CHECK(values.dim() == 2);
  TORCH_CHECK(lengths.dim() == 2);
  at::cuda::OptionalCUDAGuard device_guard;
  device_guard.set_index(values.get_device());

  const auto lengths_contig = lengths.contiguous();
  int32_t D = values.size(1);
  int32_t B = lengths.size(1);
  int32_t T = lengths.size(0);
  std::vector<Tensor> padded_values_per_key;
  std::vector<Tensor> offsets_tensor_per_key;
  for (int32_t t = 0; t < T; t++) {
    int64_t max_L = max_lengths_per_key[t];
    size_t temp_storage_bytes = 0;
    auto offsets = at::empty({B + 1}, lengths.options());
    offsets[0].zero_();
    AT_DISPATCH_INTEGRAL_TYPES(
        lengths_contig.scalar_type(), "cub_inclusive_sum_wrapper1", [&] {
          AT_CUDA_CHECK(FBGEMM_GPU_CUB_NS_PREFIX cub::DeviceScan::InclusiveSum(
              nullptr,
              temp_storage_bytes,
              &(lengths_contig.data_ptr<scalar_t>()[t * B]),
              offsets.data_ptr<scalar_t>() + 1,
              B,
              at::cuda::getCurrentCUDAStream()));
        });
    auto temp_storage = at::empty(
        {static_cast<int64_t>(temp_storage_bytes)},
        lengths.options().dtype(at::kByte));
    AT_DISPATCH_INTEGRAL_TYPES(
        lengths_contig.scalar_type(), "cub_inclusive_sum_wrapper2", [&] {
          AT_CUDA_CHECK(FBGEMM_GPU_CUB_NS_PREFIX cub::DeviceScan::InclusiveSum(
              temp_storage.data_ptr(),
              temp_storage_bytes,
              &(lengths_contig.data_ptr<scalar_t>()[t * B]),
              offsets.data_ptr<scalar_t>() + 1,
              B,
              at::cuda::getCurrentCUDAStream()));
        });
    offsets_tensor_per_key.push_back(offsets);

    padded_values_per_key.push_back(jagged_to_padded_dense(
        values.slice(0, offset_per_key[t], offset_per_key[t + 1]),
        {offsets},
        {max_L},
        /*padding_value=*/0));
  }

  return std::make_tuple(padded_values_per_key, offsets_tensor_per_key);
}

Tensor stacked_jagged_2d_to_dense_backward_cuda(
    int64_t B,
    int64_t D,
    int64_t total_L,
    const std::vector<Tensor>& grad_padded_values_per_key,
    const std::vector<Tensor>& offsets_tensor_per_key,
    const std::vector<int64_t>& offset_per_key) {
  at::cuda::OptionalCUDAGuard device_guard;
  device_guard.set_index(grad_padded_values_per_key[0].get_device());

  auto grad_values =
      at::zeros({total_L, D}, grad_padded_values_per_key[0].options());
  int32_t T = grad_padded_values_per_key.size();
  for (int32_t t = 0; t < T; t++) {
    TORCH_CHECK(grad_padded_values_per_key[t].dim() == 3);
    TORCH_CHECK(grad_padded_values_per_key[t].size(0) == B);
    TORCH_CHECK(grad_padded_values_per_key[t].size(2) == D);

    Tensor grad_values_slice =
        grad_values.slice(0, offset_per_key[t], offset_per_key[t + 1]);

    AT_DISPATCH_FLOATING_TYPES_AND_HALF(
        grad_values.scalar_type(), "jagged_2d_to_dense_backward_kernel", [&] {
          jagged_dense_elementwise_jagged_output_<scalar_t>(
              grad_values_slice, // dummy not used in the lambda function
              {offsets_tensor_per_key[t]},
              grad_padded_values_per_key[t],
              grad_values_slice,
              [] __device__(scalar_t /*unused*/, scalar_t y) -> scalar_t {
                return y;
              });
        });
  }

  return grad_values;
}

std::vector<Tensor> stacked_jagged_1d_to_dense_gpu(
    Tensor values,
    Tensor lengths,
    const std::vector<int64_t>& offset_per_key,
    const std::vector<int64_t>& max_lengths_per_key,
    int64_t padding_value) {
  TORCH_CHECK(values.dim() == 1);
  TORCH_CHECK(lengths.dim() == 2);
  at::cuda::OptionalCUDAGuard device_guard;
  device_guard.set_index(values.get_device());

  const auto lengths_contig = lengths.contiguous();
  int32_t B = lengths.size(1);
  int32_t T = lengths.size(0);
  auto offsets = at::empty({B + 1}, lengths.options());
  offsets[0].zero_();
  std::vector<Tensor> padded_values_per_key;
  for (int32_t t = 0; t < T; t++) {
    int64_t max_L = max_lengths_per_key[t];
    size_t temp_storage_bytes = 0;
    AT_DISPATCH_INTEGRAL_TYPES(
        lengths_contig.scalar_type(), "cub_inclusive_sum_wrapper1", [&] {
          AT_CUDA_CHECK(FBGEMM_GPU_CUB_NS_PREFIX cub::DeviceScan::InclusiveSum(
              nullptr,
              temp_storage_bytes,
              &(lengths_contig.data_ptr<scalar_t>()[t * B]),
              offsets.data_ptr<scalar_t>() + 1,
              B,
              at::cuda::getCurrentCUDAStream()));
        });
    auto temp_storage = at::empty(
        {static_cast<int64_t>(temp_storage_bytes)},
        lengths.options().dtype(at::kByte));
    AT_DISPATCH_INTEGRAL_TYPES(
        lengths_contig.scalar_type(), "cub_inclusive_sum_wrapper2", [&] {
          AT_CUDA_CHECK(FBGEMM_GPU_CUB_NS_PREFIX cub::DeviceScan::InclusiveSum(
              temp_storage.data_ptr(),
              temp_storage_bytes,
              &(lengths_contig.data_ptr<scalar_t>()[t * B]),
              offsets.data_ptr<scalar_t>() + 1,
              B,
              at::cuda::getCurrentCUDAStream()));
        });

    padded_values_per_key.push_back(jagged_1d_to_dense_gpu(
        values.slice(0, offset_per_key[t], offset_per_key[t + 1]),
        offsets,
        max_L,
        padding_value));
  }

  return padded_values_per_key;
}

} // namespace fbgemm_gpu

TORCH_LIBRARY_IMPL(fbgemm, CUDA, m) {
  DISPATCH_TO_CUDA("dense_to_jagged", fbgemm_gpu::dense_to_jagged);
  DISPATCH_TO_CUDA(
      "jagged_to_padded_dense", fbgemm_gpu::jagged_to_padded_dense);
  DISPATCH_TO_CUDA("jagged_2d_to_dense", fbgemm_gpu::jagged_2d_to_dense);
  DISPATCH_TO_CUDA(
      "jagged_dense_elementwise_add", fbgemm_gpu::jagged_dense_elementwise_add);
  DISPATCH_TO_CUDA(
      "jagged_dense_elementwise_add_jagged_output",
      fbgemm_gpu::jagged_dense_elementwise_add_jagged_output);
  DISPATCH_TO_CUDA(
      "jagged_dense_elementwise_mul", fbgemm_gpu::jagged_dense_elementwise_mul);
  DISPATCH_TO_CUDA(
      "batched_dense_vec_jagged_2d_mul",
      fbgemm_gpu::batched_dense_vec_jagged_2d_mul);
}
