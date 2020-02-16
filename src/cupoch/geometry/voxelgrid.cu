#include "cupoch/geometry/voxelgrid.h"

#include "cupoch/camera/pinhole_camera_parameters.h"
#include "cupoch/geometry/boundingvolume.h"
#include "cupoch/geometry/image.h"
#include <thrust/iterator/discard_iterator.h>

using namespace cupoch;
using namespace cupoch::geometry;

namespace {

struct elementwise_min_functor {
    __device__
    Eigen::Vector3i operator()(const Eigen::Vector3i& a, const Eigen::Vector3i& b) {
        return a.array().min(b.array()).matrix();
    }
};

struct elementwise_max_functor {
    __device__
    Eigen::Vector3i operator()(const Eigen::Vector3i& a, const Eigen::Vector3i& b) {
        return a.array().max(b.array()).matrix();
    }
};

struct compute_center_functor {
    compute_center_functor(float voxel_size, const Eigen::Vector3f& origin, const Eigen::Vector3f& half_voxel_size)
     : voxel_size_(voxel_size), origin_(origin), half_voxel_size_(half_voxel_size) {};
    const float voxel_size_;
    const Eigen::Vector3f origin_;
    const Eigen::Vector3f half_voxel_size_;
    __device__
    Eigen::Vector3f operator()(const Eigen::Vector3i& x) const {
        return x.cast<float>() * voxel_size_ + origin_ + half_voxel_size_;
    }
};

struct extract_grid_index_functor {
    __device__
    Eigen::Vector3i operator() (const Voxel& voxel) const {
        return voxel.grid_index_;
    }
};

struct add_voxel_color_functor {
    __device__
    Voxel operator() (const Voxel& x, const Voxel& y) const {
        Voxel ans;
        ans.grid_index_ = x.grid_index_;
        ans.color_ = x.color_ + y.color_;
        return ans;
    }
};

struct devide_voxel_color_functor {
    __device__
    Voxel operator() (const Voxel& x, int y) const {
        Voxel ans;
        ans.grid_index_ = x.grid_index_;
        ans.color_ = x.color_ / y;
        return ans;
    }
};

__host__ __device__
void GetVoxelBoundingPoints(const Eigen::Vector3f& x, float r,
                            Eigen::Vector3f points[8]) {
    points[0] = x + Eigen::Vector3f(-r, -r, -r);
    points[1] = x + Eigen::Vector3f(-r, -r, r);
    points[2] = x + Eigen::Vector3f(r, -r, -r);
    points[3] = x + Eigen::Vector3f(r, -r, r);
    points[4] = x + Eigen::Vector3f(-r, r, -r);
    points[5] = x + Eigen::Vector3f(-r, r, r);
    points[6] = x + Eigen::Vector3f(r, r, -r);
    points[7] = x + Eigen::Vector3f(r, r, r);
}

struct compute_carve_functor {
    compute_carve_functor(const uint8_t* image, int width, int height,
                          int num_of_channels, int bytes_per_channel,
                          float voxel_size, const Eigen::Vector3f& origin,
                          const Eigen::Matrix3f& intrinsic,
                          const Eigen::Matrix3f& rot, const Eigen::Vector3f& trans,
                          bool keep_voxels_outside_image)
                          : image_(image), width_(width), height_(height),
                            num_of_channels_(num_of_channels), bytes_per_channel_(bytes_per_channel),
                            voxel_size_(voxel_size), origin_(origin),
                            intrinsic_(intrinsic), rot_(rot), trans_(trans),
                            keep_voxels_outside_image_(keep_voxels_outside_image) {};
    const uint8_t* image_;
    const int width_;
    const int height_;
    const int num_of_channels_;
    const int bytes_per_channel_;
    const float voxel_size_;
    const Eigen::Vector3f origin_;
    const Eigen::Matrix3f intrinsic_;
    const Eigen::Matrix3f rot_;
    const Eigen::Vector3f trans_;
    bool keep_voxels_outside_image_;
    __device__
    bool operator() (const thrust::tuple<Eigen::Vector3i, Voxel>& voxel) const {
        bool carve = true;
        float r = voxel_size_ / 2.0;
        Voxel v = thrust::get<1>(voxel);
        auto x = ((v.grid_index_.cast<float>() + Eigen::Vector3f(0.5, 0.5, 0.5)) * voxel_size_) + origin_;
        Eigen::Vector3f pts[8];
        GetVoxelBoundingPoints(x, r, pts);
        for (int i = 0; i < 8; ++i) {
            auto x_trans = rot_ * pts[i] + trans_;
            auto uvz = intrinsic_ * x_trans;
            float z = uvz(2);
            float u = uvz(0) / z;
            float v = uvz(1) / z;
            float d;
            bool within_boundary;
            thrust::tie(within_boundary, d) = FloatValueAt(image_,
                                                           u, v, width_, height_,
                                                           num_of_channels_, bytes_per_channel_);
            if ((!within_boundary && keep_voxels_outside_image_) ||
                (within_boundary && d > 0 && z >= d)) {
                carve = false;
                break;
            }
        }
        return carve;
    }
};

}

VoxelGrid::VoxelGrid() : Geometry3D(Geometry::GeometryType::VoxelGrid) {}
VoxelGrid::~VoxelGrid() {}

VoxelGrid::VoxelGrid(const VoxelGrid &src_voxel_grid)
    : Geometry3D(Geometry::GeometryType::VoxelGrid),
      voxel_size_(src_voxel_grid.voxel_size_),
      origin_(src_voxel_grid.origin_),
      voxels_keys_(src_voxel_grid.voxels_keys_),
      voxels_values_(src_voxel_grid.voxels_values_) {}

VoxelGrid &VoxelGrid::Clear() {
    voxel_size_ = 0.0;
    origin_ = Eigen::Vector3f::Zero();
    voxels_keys_.clear();
    voxels_values_.clear();
    return *this;
}

bool VoxelGrid::IsEmpty() const { return !HasVoxels(); }

Eigen::Vector3f VoxelGrid::GetMinBound() const {
    if (!HasVoxels()) {
        return origin_;
    } else {
        Voxel v = voxels_values_[0];
        Eigen::Vector3i init = v.grid_index_;
        Eigen::Vector3i min_grid_index = thrust::reduce(thrust::make_transform_iterator(voxels_values_.begin(), extract_grid_index_functor()),
                                                        thrust::make_transform_iterator(voxels_values_.end(), extract_grid_index_functor()),
                                                        init, elementwise_min_functor());
        return min_grid_index.cast<float>() * voxel_size_ + origin_;
    }
}

Eigen::Vector3f VoxelGrid::GetMaxBound() const {
    if (!HasVoxels()) {
        return origin_;
    } else {
        Voxel v = voxels_values_[0];
        Eigen::Vector3i init = v.grid_index_;
        Eigen::Vector3i min_grid_index = thrust::reduce(thrust::make_transform_iterator(voxels_values_.begin(), extract_grid_index_functor()),
                                                        thrust::make_transform_iterator(voxels_values_.end(), extract_grid_index_functor()),
                                                        init, elementwise_max_functor());
        return (min_grid_index.cast<float>() + Eigen::Vector3f::Ones()) * voxel_size_ + origin_;
    }
}

Eigen::Vector3f VoxelGrid::GetCenter() const {
    Eigen::Vector3f init(0, 0, 0);
    if (!HasVoxels()) {
        return init;
    }
    const Eigen::Vector3f half_voxel_size(0.5 * voxel_size_, 0.5 * voxel_size_,
                                          0.5 * voxel_size_);
    compute_center_functor func(voxel_size_, origin_, half_voxel_size);
    Eigen::Vector3f center = thrust::transform_reduce(thrust::make_transform_iterator(voxels_values_.begin(), extract_grid_index_functor()),
                                                      thrust::make_transform_iterator(voxels_values_.end(), extract_grid_index_functor()),
                                                      func, init, thrust::plus<Eigen::Vector3f>());
    center /= float(voxels_values_.size());
    return center;
}

AxisAlignedBoundingBox VoxelGrid::GetAxisAlignedBoundingBox() const {
    AxisAlignedBoundingBox box;
    box.min_bound_ = GetMinBound();
    box.max_bound_ = GetMaxBound();
    return box;
}

OrientedBoundingBox VoxelGrid::GetOrientedBoundingBox() const {
    return OrientedBoundingBox::CreateFromAxisAlignedBoundingBox(
            GetAxisAlignedBoundingBox());
}

VoxelGrid &VoxelGrid::Transform(const Eigen::Matrix4f &transformation) {
    utility::LogError("VoxelGrid::Transform is not supported");
    return *this;
}

VoxelGrid &VoxelGrid::Translate(const Eigen::Vector3f &translation,
                                bool relative) {
    utility::LogError("Not implemented");
    return *this;
}

VoxelGrid &VoxelGrid::Scale(const float scale, bool center) {
    utility::LogError("Not implemented");
    return *this;
}

VoxelGrid &VoxelGrid::Rotate(const Eigen::Matrix3f &R, bool center) {
    utility::LogError("VoxelGrid::Transform is not supported");
    return *this;
}

VoxelGrid &VoxelGrid::operator+=(const VoxelGrid &voxelgrid) {
    if (voxel_size_ != voxelgrid.voxel_size_) {
        utility::LogError(
                "[VoxelGrid] Could not combine VoxelGrid because voxel_size "
                "differs (this=%f, other=%f)",
                voxel_size_, voxelgrid.voxel_size_);
    }
    if (origin_ != voxelgrid.origin_) {
        utility::LogError(
                "[VoxelGrid] Could not combine VoxelGrid because origin "
                "differs (this=%f,%f,%f, other=%f,%f,%f)",
                origin_(0), origin_(1), origin_(2), voxelgrid.origin_(0),
                voxelgrid.origin_(1), voxelgrid.origin_(2));
    }
    if (this->HasColors() != voxelgrid.HasColors()) {
        utility::LogError(
                "[VoxelGrid] Could not combine VoxelGrid one has colors and "
                "the other not.");
    }
    if (voxelgrid.HasColors()) {
        voxels_keys_.insert(voxels_keys_.end(), voxelgrid.voxels_keys_.begin(), voxelgrid.voxels_keys_.end());
        voxels_values_.insert(voxels_values_.end(), voxelgrid.voxels_values_.begin(), voxelgrid.voxels_values_.end());
        thrust::sort_by_key(voxels_keys_.begin(), voxels_keys_.end(), voxels_values_.begin());
        thrust::device_vector<int> counts(voxels_keys_.size());
        thrust::device_vector<Eigen::Vector3i> new_keys(voxels_keys_.size());
        auto end1 = thrust::reduce_by_key(voxels_keys_.begin(), voxels_keys_.end(),
                                          thrust::make_constant_iterator(1),
                                          thrust::make_discard_iterator(), counts.begin());
        int n_out = thrust::distance(counts.begin(), end1.second);
        counts.resize(n_out);
        auto end2 = thrust::reduce_by_key(voxels_keys_.begin(), voxels_keys_.end(),
                                          voxels_values_.begin(), new_keys.begin(),
                                          voxels_values_.begin(),
                                          thrust::equal_to<Eigen::Vector3i>(),
                                          add_voxel_color_functor());
        new_keys.resize(n_out);
        voxels_keys_ = new_keys;
        voxels_values_.resize(n_out);
        thrust::transform(voxels_values_.begin(), voxels_values_.end(),
                          counts.begin(), voxels_values_.begin(),
                          devide_voxel_color_functor());
    } else {
        this->AddVoxels(voxelgrid.voxels_values_);
    }
    return *this;
}

VoxelGrid VoxelGrid::operator+(const VoxelGrid &voxelgrid) const {
    return (VoxelGrid(*this) += voxelgrid);
}

void VoxelGrid::AddVoxel(const Voxel &voxel) {
    voxels_keys_.push_back(voxel.grid_index_);
    voxels_values_.push_back(voxel);
    thrust::sort_by_key(voxels_keys_.begin(), voxels_keys_.end(), voxels_values_.begin());
    auto end = thrust::unique_by_key(voxels_keys_.begin(), voxels_keys_.end(), voxels_values_.begin());
    size_t out_size = thrust::distance(voxels_keys_.begin(), end.first);
    voxels_keys_.resize(out_size);
    voxels_values_.resize(out_size);
}

void VoxelGrid::AddVoxels(const thrust::device_vector<Voxel> &voxels) {
    voxels_keys_.insert(voxels_keys_.end(),
                        thrust::make_transform_iterator(voxels.begin(), extract_grid_index_functor()),
                        thrust::make_transform_iterator(voxels.end(), extract_grid_index_functor()));
    voxels_values_.insert(voxels_values_.end(), voxels.begin(), voxels.end());
    thrust::sort_by_key(voxels_keys_.begin(), voxels_keys_.end(), voxels_values_.begin());
    auto end = thrust::unique_by_key(voxels_keys_.begin(), voxels_keys_.end(), voxels_values_.begin());
    size_t out_size = thrust::distance(voxels_keys_.begin(), end.first);
    voxels_keys_.resize(out_size);
    voxels_values_.resize(out_size);
}

Eigen::Vector3i VoxelGrid::GetVoxel(const Eigen::Vector3f &point) const {
    Eigen::Vector3f voxel_f = (point - origin_) / voxel_size_;
    return (Eigen::floor(voxel_f.array())).cast<int>();
}

Eigen::Vector3f VoxelGrid::GetVoxelCenterCoordinate(const Eigen::Vector3i &idx) const {
    auto it = thrust::find(voxels_keys_.begin(), voxels_keys_.end(), idx);
    if (it != voxels_keys_.end()) {
        Eigen::Vector3i voxel_idx = *it;
        return ((voxel_idx.cast<float>() +
                 Eigen::Vector3f(0.5, 0.5, 0.5)) *
                voxel_size_) +
               origin_;
    } else {
        return Eigen::Vector3f::Zero();
    }
}

std::array<Eigen::Vector3f, 8> VoxelGrid::GetVoxelBoundingPoints(
        const Eigen::Vector3i &index) const {
    float r = voxel_size_ / 2.0;
    auto x = GetVoxelCenterCoordinate(index);
    std::array<Eigen::Vector3f, 8> points;
    ::GetVoxelBoundingPoints(x, r, points.data());
    return points;
}

thrust::host_vector<bool> VoxelGrid::CheckIfIncluded(
        const thrust::host_vector<Eigen::Vector3f> &queries) {
    thrust::host_vector<bool> output;
    output.resize(queries.size());
    for (size_t i = 0; i < queries.size(); ++i) {
        auto query = GetVoxel(queries[i]);
        auto itr = thrust::find(thrust::cuda::par.on(utility::GetStream(i % utility::MAX_NUM_STREAMS)),
                                voxels_keys_.begin(), voxels_keys_.end(), query);
        output[i] = (itr != voxels_keys_.end());
    }
    cudaSafeCall(cudaDeviceSynchronize());
    return output;
}

VoxelGrid &VoxelGrid::CarveDepthMap(
        const Image &depth_map,
        const camera::PinholeCameraParameters &camera_parameter,
        bool keep_voxels_outside_image) {
    if (depth_map.height_ != camera_parameter.intrinsic_.height_ ||
        depth_map.width_ != camera_parameter.intrinsic_.width_) {
        utility::LogError(
                "[VoxelGrid] provided depth_map dimensions are not compatible "
                "with the provided camera_parameters");
    }

    auto rot = camera_parameter.extrinsic_.block<3, 3>(0, 0);
    auto trans = camera_parameter.extrinsic_.block<3, 1>(0, 3);
    auto intrinsic = camera_parameter.intrinsic_.intrinsic_matrix_;

    // get for each voxel if it projects to a valid pixel and check if the voxel
    // depth is behind the depth of the depth map at the projected pixel.
    compute_carve_functor func(thrust::raw_pointer_cast(depth_map.data_.data()),
                               depth_map.width_, depth_map.height_,
                               depth_map.num_of_channels_, depth_map.bytes_per_channel_,
                               voxel_size_, origin_,
                               intrinsic, rot, trans, keep_voxels_outside_image);
    auto begin = make_tuple_iterator(voxels_keys_.begin(), voxels_values_.begin());
    auto end = thrust::remove_if(begin, make_tuple_iterator(voxels_keys_.end(), voxels_values_.end()), func);
    size_t out_size = thrust::distance(begin, end);
    voxels_keys_.resize(out_size);
    voxels_values_.resize(out_size);
    return *this;
}

VoxelGrid &VoxelGrid::CarveSilhouette(
        const Image &silhouette_mask,
        const camera::PinholeCameraParameters &camera_parameter,
        bool keep_voxels_outside_image) {
    if (silhouette_mask.height_ != camera_parameter.intrinsic_.height_ ||
        silhouette_mask.width_ != camera_parameter.intrinsic_.width_) {
        utility::LogError(
                "[VoxelGrid] provided silhouette_mask dimensions are not "
                "compatible with the provided camera_parameters");
    }

    auto rot = camera_parameter.extrinsic_.block<3, 3>(0, 0);
    auto trans = camera_parameter.extrinsic_.block<3, 1>(0, 3);
    auto intrinsic = camera_parameter.intrinsic_.intrinsic_matrix_;

    // get for each voxel if it projects to a valid pixel and check if the pixel
    // is set (>0).
    compute_carve_functor func(thrust::raw_pointer_cast(silhouette_mask.data_.data()),
                               silhouette_mask.width_, silhouette_mask.height_,
                               silhouette_mask.num_of_channels_, silhouette_mask.bytes_per_channel_,
                               voxel_size_, origin_,
                               intrinsic, rot, trans, keep_voxels_outside_image);
    auto begin = make_tuple_iterator(voxels_keys_.begin(), voxels_values_.begin());
    auto end = thrust::remove_if(begin, make_tuple_iterator(voxels_keys_.end(), voxels_values_.end()), func);
    size_t out_size = thrust::distance(begin, end);
    voxels_keys_.resize(out_size);
    voxels_values_.resize(out_size);
    return *this;
}
