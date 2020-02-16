#include "cupoch/camera/pinhole_camera_intrinsic.h"
#include "cupoch/geometry/image.h"
#include "cupoch/utility/console.h"

using namespace cupoch;
using namespace cupoch::geometry;

namespace {

struct compute_camera_distance_functor {
    compute_camera_distance_functor(uint8_t* data, int width,
                                    const float* xx, const float* yy)
                                    : data_(data), width_(width),
                                      xx_(xx), yy_(yy) {};
    uint8_t* data_;
    const int width_;
    const float* xx_;
    const float* yy_;
    __device__
    void operator() (size_t idx) {
        int i = idx / width_;
        int j = idx % width_;
        float *fp =
                (float *)(data_ + idx * sizeof(float));
        *fp = sqrtf(xx_[j] * xx_[j] + yy_[i] * yy_[i] + 1.0f);
    }
};

struct make_float_image_functor {
    make_float_image_functor(const uint8_t* image, int num_of_channels,
                             int bytes_per_channel,
                             Image::ColorToIntensityConversionType type,
                             uint8_t* fimage)
                             : image_(image), num_of_channels_(num_of_channels),
                               bytes_per_channel_(bytes_per_channel),
                               type_(type), fimage_(fimage) {};
    const uint8_t* image_;
    int num_of_channels_;
    int bytes_per_channel_;
    Image::ColorToIntensityConversionType type_;
    uint8_t* fimage_;
    __device__
    void operator() (size_t idx) {
        float *p = (float *)(fimage_ + idx * 4);
        const uint8_t *pi =
                image_ + idx * num_of_channels_ * bytes_per_channel_;
        if (num_of_channels_ == 1) {
            // grayscale image
            if (bytes_per_channel_ == 1) {
                *p = (float)(*pi) / 255.0f;
            } else if (bytes_per_channel_ == 2) {
                const uint16_t *pi16 = (const uint16_t *)pi;
                *p = (float)(*pi16);
            } else if (bytes_per_channel_ == 4) {
                const float *pf = (const float *)pi;
                *p = *pf;
            }
        } else if (num_of_channels_ == 3) {
            if (bytes_per_channel_ == 1) {
                if (type_ == Image::ColorToIntensityConversionType::Equal) {
                    *p = ((float)(pi[0]) + (float)(pi[1]) + (float)(pi[2])) /
                         3.0f / 255.0f;
                } else if (type_ ==
                           Image::ColorToIntensityConversionType::Weighted) {
                    *p = (0.2990f * (float)(pi[0]) + 0.5870f * (float)(pi[1]) +
                          0.1140f * (float)(pi[2])) /
                         255.0f;
                }
            } else if (bytes_per_channel_ == 2) {
                const uint16_t *pi16 = (const uint16_t *)pi;
                if (type_ == Image::ColorToIntensityConversionType::Equal) {
                    *p = ((float)(pi16[0]) + (float)(pi16[1]) +
                          (float)(pi16[2])) /
                         3.0f;
                } else if (type_ ==
                           Image::ColorToIntensityConversionType::Weighted) {
                    *p = (0.2990f * (float)(pi16[0]) +
                          0.5870f * (float)(pi16[1]) +
                          0.1140f * (float)(pi16[2]));
                }
            } else if (bytes_per_channel_ == 4) {
                const float *pf = (const float *)pi;
                if (type_ == Image::ColorToIntensityConversionType::Equal) {
                    *p = (pf[0] + pf[1] + pf[2]) / 3.0f;
                } else if (type_ ==
                           Image::ColorToIntensityConversionType::Weighted) {
                    *p = (0.2990f * pf[0] + 0.5870f * pf[1] + 0.1140f * pf[2]);
                }
            }
        }
    }
};

template<typename T>
struct restore_from_float_image_functor {
    restore_from_float_image_functor(const float* src, uint8_t* dst)
        : src_(src), dst_(dst) {};
    const float* src_;
    uint8_t* dst_;
    __device__
    void operator() (size_t idx) {
        if (sizeof(T) == 1) *(dst_ + idx) = static_cast<T>(*(src_ + idx) * 255.0f);
        if (sizeof(T) == 2) *(dst_ + idx) = static_cast<T>(*(src_ + idx));
    }
};

}

std::shared_ptr<Image> Image::CreateDepthToCameraDistanceMultiplierFloatImage(
        const camera::PinholeCameraIntrinsic &intrinsic) {
    auto fimage = std::make_shared<Image>();
    fimage->Prepare(intrinsic.width_, intrinsic.height_, 1, 4);
    float ffl_inv0 = 1.0f / (float)intrinsic.GetFocalLength().first;
    float ffl_inv1 = 1.0f / (float)intrinsic.GetFocalLength().second;
    float fpp0 = (float)intrinsic.GetPrincipalPoint().first;
    float fpp1 = (float)intrinsic.GetPrincipalPoint().second;
    thrust::device_vector<float> xx(intrinsic.width_);
    thrust::device_vector<float> yy(intrinsic.height_);
    thrust::tabulate(thrust::cuda::par.on(utility::GetStream(0)), xx.begin(), xx.end(),
                     [=] __device__ (int idx) {return (idx - fpp0) * ffl_inv0;});
    thrust::tabulate(thrust::cuda::par.on(utility::GetStream(1)), yy.begin(), yy.end(),
                     [=] __device__ (int idx) {return (idx - fpp1) * ffl_inv1;});
    cudaSafeCall(cudaDeviceSynchronize());
    compute_camera_distance_functor func(thrust::raw_pointer_cast(fimage->data_.data()),
                                         intrinsic.width_,
                                         thrust::raw_pointer_cast(xx.data()),
                                         thrust::raw_pointer_cast(yy.data()));
    for_each(thrust::make_counting_iterator<size_t>(0),
             thrust::make_counting_iterator<size_t>(intrinsic.height_ * intrinsic.width_),
             func);
    return fimage;
}

std::shared_ptr<Image> Image::CreateFloatImage(
        Image::ColorToIntensityConversionType type /* = WEIGHTED*/) const {
    auto fimage = std::make_shared<Image>();
    if (IsEmpty()) {
        return fimage;
    }
    fimage->Prepare(width_, height_, 1, 4);
    make_float_image_functor func(thrust::raw_pointer_cast(data_.data()),
                                  num_of_channels_, bytes_per_channel_, type,
                                  thrust::raw_pointer_cast(fimage->data_.data()));
    thrust::for_each(thrust::make_counting_iterator<size_t>(0), 
                     thrust::make_counting_iterator<size_t>(width_ * height_), func);
    return fimage;
}

template <typename T>
std::shared_ptr<Image> Image::CreateImageFromFloatImage() const {
    auto output = std::make_shared<Image>();
    if (num_of_channels_ != 1 || bytes_per_channel_ != 4) {
        utility::LogError(
                "[CreateImageFromFloatImage] Unsupported image format.");
    }

    output->Prepare(width_, height_, num_of_channels_, sizeof(T));
    restore_from_float_image_functor<T> func((const float*)thrust::raw_pointer_cast(data_.data()),
                                             thrust::raw_pointer_cast(output->data_.data()));
    thrust::for_each(thrust::make_counting_iterator<size_t>(0), thrust::make_counting_iterator<size_t>(width_ * height_), func);
    return output;
}

template std::shared_ptr<Image> Image::CreateImageFromFloatImage<uint8_t>()
        const;
template std::shared_ptr<Image> Image::CreateImageFromFloatImage<uint16_t>()
        const;

ImagePyramid Image::CreatePyramid(size_t num_of_levels,
                                  bool with_gaussian_filter /*= true*/) const {
    std::vector<std::shared_ptr<Image>> pyramid_image;
    pyramid_image.clear();
    if ((num_of_channels_ != 1) || (bytes_per_channel_ != 4)) {
        utility::LogError("[CreateImagePyramid] Unsupported image format.");
    }

    for (size_t i = 0; i < num_of_levels; i++) {
        if (i == 0) {
            std::shared_ptr<Image> input_copy_ptr = std::make_shared<Image>();
            *input_copy_ptr = *this;
            pyramid_image.push_back(input_copy_ptr);
        } else {
            if (with_gaussian_filter) {
                // https://en.wikipedia.org/wiki/Pyramid_(image_processing)
                auto level_b = pyramid_image[i - 1]->Filter(
                        Image::FilterType::Gaussian3);
                auto level_bd = level_b->Downsample();
                pyramid_image.push_back(level_bd);
            } else {
                auto level_d = pyramid_image[i - 1]->Downsample();
                pyramid_image.push_back(level_d);
            }
        }
    }
    return pyramid_image;
}