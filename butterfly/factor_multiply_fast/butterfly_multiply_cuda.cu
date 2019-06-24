#include <stdio.h>
#include <ATen/ATen.h>
#include <ATen/AccumulateType.h>
#include <ATen/cuda/CUDAContext.h>
#include <THC/THCAtomics.cuh>  // For atomicAdd on Half
#include <c10/macros/Macros.h>  // For __launch_bounds__
#include <thrust/complex.h>
#include <thrust/pair.h>
#include <thrust/tuple.h>

#define thc_cos std::cos
#define thc_sin std::sin

#define FULL_MASK 0xffffffff

// static constexpr int MAX_BLOCK_SIZE = 1024;
// static constexpr int WORK_PER_THREAD = 16;
// static constexpr int ELEMENTARY_SIZE = MAX_BLOCK_SIZE / 2;
// static constexpr int MAX_N_FACTORS = 10;
static constexpr int ITEMS_PER_THREAD = 4;

template <typename T, size_t N>
using CudaAcsr = at::PackedTensorAccessor<T, N, at::RestrictPtrTraits, int32_t>;

constexpr __host__ __device__ int min_const(int x, int y) { return x <= y ? x : y; }
constexpr __host__ __device__ int max_const(int x, int y) { return x >= y ? x : y; }

// __host__ __device__ static inline int64_t div_up(int64_t a, int64_t b) {
//   return (a + b - 1) / b;
// }

__host__ __device__ static inline int div_up(int a, int b) {
  return (a + b - 1) / b;
}

template <typename scalar_t>
static __device__  __forceinline__
void atomicAdd(thrust::complex<scalar_t> *address,
               thrust::complex<scalar_t> val) {
  atomicAdd((scalar_t *)address, val.real());
  atomicAdd((scalar_t *)address + 1, val.imag());
}

template <typename scalar_t>
static __device__  __forceinline__
thrust::complex<scalar_t> __shfl_down_sync(unsigned int mask,
                                           thrust::complex<scalar_t> value,
                                           unsigned int delta,
                                           int width = warpSize) {
  return thrust::complex<scalar_t>(__shfl_down_sync(mask, value.real(), delta, width),
                                   __shfl_down_sync(mask, value.imag(), delta, width));
}

// 2x2 matrix [a, b; c, d] multiplied by a vector [x, y]
template <typename scalar_t>
static __device__  __forceinline__
thrust::pair<scalar_t, scalar_t> mult2x2(scalar_t a, scalar_t b, scalar_t c,
                                         scalar_t d, scalar_t x, scalar_t y) {
  return thrust::make_pair(a * x + b * y, c * x + d * y);
}

template <int nsteps, int items_per_thread, typename scalar_t>
__device__ __forceinline__ void b_untied_forward(const CudaAcsr<scalar_t, 4> twiddle_a,
                                                 scalar_t input_val[items_per_thread],
                                                 int log_min_stride,
                                                 int id) {
  const int s = blockIdx.y + gridDim.y * blockIdx.z;  // For conv2d butterfly as well
  #pragma unroll
  for (int i = 0; i < nsteps; i++) {
    int log_stride = i + log_min_stride;
    const scalar_t twiddle_val[2] = {twiddle_a[s][log_stride][0][id],
                                     twiddle_a[s][log_stride][1][id]};
    int lane_mask = 1 << i;
    #pragma unroll
    for (int item = 0; item < items_per_thread; item++) {
      scalar_t input_val_other = __shfl_xor_sync(FULL_MASK, input_val[item], lane_mask);
      input_val[item] = twiddle_val[0] * input_val[item] + twiddle_val[1] * input_val_other;
    }
  }
}


template <int log_n, int items_per_thread, typename scalar_t, typename Function0, typename Function1>
C10_LAUNCH_BOUNDS_2(1 << log_n, 1)
__global__ void butterfly_multiply_untied_forward_fast_cuda_kernel(const CudaAcsr<scalar_t, 4> twiddle_a,
                                                                   Function0 load_input,
                                                                   Function1 save_output,
                                                                   int batch_size) {
  const int s = blockIdx.y + gridDim.y * blockIdx.z;  // For conv2d butterfly as well
  constexpr int n = 1 << log_n;
  __shared__ scalar_t s_input[n * items_per_thread];
  load_input(s_input);
  scalar_t input_val[items_per_thread];
  #pragma unroll
  for (int item = 0; item < items_per_thread; item++) {
    input_val[item] = s_input[threadIdx.x + item * n];
  }
  b_untied_forward<min_const(log_n, 5), items_per_thread>(twiddle_a, input_val, 0, threadIdx.x);
  #pragma unroll
  for (int item = 0; item < items_per_thread; item++) {
    s_input[threadIdx.x + item * n] = input_val[item];
  }
  __syncwarp();
  if (log_n > 5) {
    // Transpose
    __syncthreads();
    constexpr int log_nwarps = max_const(log_n - 5, 0);  // Take max to avoid compiler's warning
    // int id = (threadIdx.x % (1 << log_nwarps)) * warpSize + threadIdx.x / (1 << log_nwarps);
    int id = (threadIdx.x & ((1 << log_nwarps) - 1)) * warpSize + threadIdx.x >> log_nwarps;;
    #pragma unroll
    for (int item = 0; item < items_per_thread; item++) {
      input_val[item] = s_input[id + item * n];
    }
    b_untied_forward<log_n - 5, items_per_thread>(twiddle_a, input_val, 5, id);
    #pragma unroll
    for (int item = 0; item < items_per_thread; item++) {
      s_input[id + item * n] = input_val[item];
    }
    __syncthreads();
  }
  save_output(s_input);
}


void butterfly_multiply_untied_forward_fast_cuda(const at::Tensor &twiddle,
                                                 const at::Tensor &input,
                                                 at::Tensor &output) {
  int batch_size = input.size(0);
  const int nstack = input.size(1);
  const int n = input.size(2);
  const int log_n = int(log2((double) n));
  AT_DISPATCH_FLOATING_TYPES(input.scalar_type(), "butterfly_multiply_untied_forward_fast_cuda", [&] {
    using accscalar_t = at::acc_type<scalar_t, true>;
    const auto twiddle_a = twiddle.packed_accessor<scalar_t, 4, at::RestrictPtrTraits, int32_t>();
    const auto input_a = input.packed_accessor<scalar_t, 3, at::RestrictPtrTraits, int32_t>();
    auto output_a = output.packed_accessor<scalar_t, 3, at::RestrictPtrTraits, int32_t>();
    // int stride = n / 2;
    // int log_stride = log_n - 1;
    dim3 block(n);
    dim3 grid(div_up(batch_size, ITEMS_PER_THREAD), 1, nstack);
    auto load_input = [batch_size, n, input_a] __device__ (scalar_t* s_input) {
      for (int i = threadIdx.x; i < n; i += blockDim.x) {
        const int s = blockIdx.z;
        #pragma unroll
        for (int item = 0; item < ITEMS_PER_THREAD; item++){
          const int b = blockIdx.x * ITEMS_PER_THREAD + item;
          s_input[i + item * n] = b < batch_size ? input_a[b][s][i] : 0;
        }
      }
    };
    auto save_output = [batch_size, n, output_a] __device__ (scalar_t* s_input) mutable {
      for (int i = threadIdx.x; i < n; i += blockDim.x) {
        const int s = blockIdx.z;
        #pragma unroll
        for (int item = 0; item < ITEMS_PER_THREAD; item++){
          const int b = blockIdx.x * ITEMS_PER_THREAD + item;
          if (b < batch_size) {
            output_a[b][s][i] = s_input[i + item * n];
          }
        }
      }
    };
    auto stream = at::cuda::getCurrentCUDAStream();
    switch (log_n)
      {
      case 1:
        butterfly_multiply_untied_forward_fast_cuda_kernel<1, ITEMS_PER_THREAD>
          <<<grid, block, 0, stream>>>(twiddle_a, load_input, save_output, batch_size); break;
      case 2:
        butterfly_multiply_untied_forward_fast_cuda_kernel<2, ITEMS_PER_THREAD>
          <<<grid, block, 0, stream>>>(twiddle_a, load_input, save_output, batch_size); break;
      case 3:
        butterfly_multiply_untied_forward_fast_cuda_kernel<3, ITEMS_PER_THREAD>
          <<<grid, block, 0, stream>>>(twiddle_a, load_input, save_output, batch_size); break;
      case 4:
        butterfly_multiply_untied_forward_fast_cuda_kernel<4, ITEMS_PER_THREAD>
          <<<grid, block, 0, stream>>>(twiddle_a, load_input, save_output, batch_size); break;
      case 5:
        butterfly_multiply_untied_forward_fast_cuda_kernel<5, ITEMS_PER_THREAD>
          <<<grid, block, 0, stream>>>(twiddle_a, load_input, save_output, batch_size); break;
      case 6:
        butterfly_multiply_untied_forward_fast_cuda_kernel<6, ITEMS_PER_THREAD>
          <<<grid, block, 0, stream>>>(twiddle_a, load_input, save_output, batch_size); break;
      case 7:
        butterfly_multiply_untied_forward_fast_cuda_kernel<7, ITEMS_PER_THREAD>
          <<<grid, block, 0, stream>>>(twiddle_a, load_input, save_output, batch_size); break;
      case 8:
        butterfly_multiply_untied_forward_fast_cuda_kernel<8, ITEMS_PER_THREAD>
          <<<grid, block, 0, stream>>>(twiddle_a, load_input, save_output, batch_size); break;
      case 9:
        butterfly_multiply_untied_forward_fast_cuda_kernel<9, ITEMS_PER_THREAD>
          <<<grid, block, 0, stream>>>(twiddle_a, load_input, save_output, batch_size); break;
      case 10:
        butterfly_multiply_untied_forward_fast_cuda_kernel<10, ITEMS_PER_THREAD>
          <<<grid, block, 0, stream>>>(twiddle_a, load_input, save_output, batch_size); break;
      }
  });
  AT_CHECK(cudaGetLastError() == cudaSuccess,
     "butterfly_multiply_untied_forward_fast_cuda failed with error code ",
     cudaGetLastError());
}