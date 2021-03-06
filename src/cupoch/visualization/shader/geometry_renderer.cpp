#include "cupoch/visualization/shader/geometry_renderer.h"
#include "cupoch/geometry/pointcloud.h"
#include "cupoch/geometry/trianglemesh.h"

using namespace cupoch;
using namespace cupoch::visualization;
using namespace cupoch::visualization::glsl;

bool PointCloudRenderer::Render(const RenderOption &option,
                                const ViewControl &view) {
    if (is_visible_ == false || geometry_ptr_->IsEmpty()) return true;
    const auto &pointcloud = (const geometry::PointCloud &)(*geometry_ptr_);
    bool success = true;
    if (pointcloud.HasNormals()) {
        if (option.point_color_option_ ==
            RenderOption::PointColorOption::Normal) {
            success &= normal_point_shader_.Render(pointcloud, option, view);
        } else {
            success &= phong_point_shader_.Render(pointcloud, option, view);
        }
        if (option.point_show_normal_) {
            success &=
                    simplewhite_normal_shader_.Render(pointcloud, option, view);
        }
    } else {
        success &= simple_point_shader_.Render(pointcloud, option, view);
    }
    return success;
}

bool PointCloudRenderer::AddGeometry(
        std::shared_ptr<const geometry::Geometry> geometry_ptr) {
    if (geometry_ptr->GetGeometryType() !=
        geometry::Geometry::GeometryType::PointCloud) {
        return false;
    }
    geometry_ptr_ = geometry_ptr;
    return UpdateGeometry();
}

bool PointCloudRenderer::UpdateGeometry() {
    simple_point_shader_.InvalidateGeometry();
    phong_point_shader_.InvalidateGeometry();
    normal_point_shader_.InvalidateGeometry();
    simplewhite_normal_shader_.InvalidateGeometry();
    return true;
}

bool TriangleMeshRenderer::Render(const RenderOption &option,
                                  const ViewControl &view) {
    if (is_visible_ == false || geometry_ptr_->IsEmpty()) return true;
    const auto &mesh = (const geometry::TriangleMesh &)(*geometry_ptr_);
    bool success = true;
    if (mesh.HasTriangleNormals() && mesh.HasVertexNormals()) {
        if (option.mesh_color_option_ ==
            RenderOption::MeshColorOption::Normal) {
            success &= normal_mesh_shader_.Render(mesh, option, view);
        } else if (option.mesh_color_option_ ==
                           RenderOption::MeshColorOption::Color &&
                   mesh.HasTriangleUvs() && mesh.HasTexture()) {
            success &= texture_phong_mesh_shader_.Render(mesh, option, view);
        } else {
            success &= phong_mesh_shader_.Render(mesh, option, view);
        }
    } else {  // if normals are not ready
        if (option.mesh_color_option_ == RenderOption::MeshColorOption::Color &&
            mesh.HasTriangleUvs() && mesh.HasTexture()) {
            success &= texture_simple_mesh_shader_.Render(mesh, option, view);
        } else {
            success &= simple_mesh_shader_.Render(mesh, option, view);
        }
    }
    if (option.mesh_show_wireframe_) {
        success &= simplewhite_wireframe_shader_.Render(mesh, option, view);
    }
    return success;
}

bool TriangleMeshRenderer::AddGeometry(
        std::shared_ptr<const geometry::Geometry> geometry_ptr) {
    if (geometry_ptr->GetGeometryType() !=
                geometry::Geometry::GeometryType::TriangleMesh) {
        return false;
    }
    geometry_ptr_ = geometry_ptr;
    return UpdateGeometry();
}

bool TriangleMeshRenderer::UpdateGeometry() {
    simple_mesh_shader_.InvalidateGeometry();
    texture_simple_mesh_shader_.InvalidateGeometry();
    phong_mesh_shader_.InvalidateGeometry();
    texture_phong_mesh_shader_.InvalidateGeometry();
    normal_mesh_shader_.InvalidateGeometry();
    simplewhite_wireframe_shader_.InvalidateGeometry();
    return true;
}

bool ImageRenderer::Render(const RenderOption &option,
                           const ViewControl &view) {
    if (is_visible_ == false || geometry_ptr_->IsEmpty()) return true;
    return image_shader_.Render(*geometry_ptr_, option, view);
}

bool ImageRenderer::AddGeometry(
        std::shared_ptr<const geometry::Geometry> geometry_ptr) {
    if (geometry_ptr->GetGeometryType() !=
        geometry::Geometry::GeometryType::Image) {
        return false;
    }
    geometry_ptr_ = geometry_ptr;
    return UpdateGeometry();
}

bool ImageRenderer::UpdateGeometry() {
    image_shader_.InvalidateGeometry();
    return true;
}

bool CoordinateFrameRenderer::Render(const RenderOption &option,
                                     const ViewControl &view) {
    if (is_visible_ == false || geometry_ptr_->IsEmpty()) return true;
    if (option.show_coordinate_frame_ == false) return true;
    const auto &mesh = (const geometry::TriangleMesh &)(*geometry_ptr_);
    return phong_shader_.Render(mesh, option, view);
}

bool CoordinateFrameRenderer::AddGeometry(
        std::shared_ptr<const geometry::Geometry> geometry_ptr) {
    if (geometry_ptr->GetGeometryType() !=
                geometry::Geometry::GeometryType::TriangleMesh) {
        return false;
    }
    geometry_ptr_ = geometry_ptr;
    return UpdateGeometry();
}

bool CoordinateFrameRenderer::UpdateGeometry() {
    phong_shader_.InvalidateGeometry();
    return true;
}
