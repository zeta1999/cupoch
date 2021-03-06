#pragma once

// Avoid warning caused by redefinition of APIENTRY macro
// defined also in glfw3.h
#ifdef _WIN32
#include <windows.h>
#endif

#include <GL/glew.h>  // Make sure glew.h is included before gl.h
#include <GLFW/glfw3.h>
#include <Eigen/Core>
#include <string>

namespace cupoch {
namespace visualization {
namespace gl_helper {

typedef Eigen::Matrix<GLfloat, 3, 1, Eigen::ColMajor> GLVector3f;
typedef Eigen::Matrix<GLfloat, 4, 1, Eigen::ColMajor> GLVector4f;
typedef Eigen::Matrix<GLfloat, 4, 4, Eigen::ColMajor> GLMatrix4f;

GLMatrix4f LookAt(const Eigen::Vector3f &eye,
                  const Eigen::Vector3f &lookat,
                  const Eigen::Vector3f &up);

GLMatrix4f Perspective(float field_of_view_,
                       float aspect,
                       float z_near,
                       float z_far);

GLMatrix4f Ortho(float left,
                 float right,
                 float bottom,
                 float top,
                 float z_near,
                 float z_far);

Eigen::Vector3f Project(const Eigen::Vector3f &point,
                        const GLMatrix4f &mvp_matrix,
                        const int width,
                        const int height);

Eigen::Vector3f Unproject(const Eigen::Vector3f &screen_point,
                          const GLMatrix4f &mvp_matrix,
                          const int width,
                          const int height);

int ColorCodeToPickIndex(const Eigen::Vector4i &color);

}  // namespace gl_helper
}  // namespace visualization
}  // namespace cupoch