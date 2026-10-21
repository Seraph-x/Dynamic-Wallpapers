#include "LocalProjectFiles.hpp"
#include <cerrno>
#include <fcntl.h>
#include <filesystem>
#include <stdexcept>
#include <system_error>
#include <sys/stat.h>
#include <unistd.h>
#include <utility>

namespace dw {
namespace fs = std::filesystem;

static std::system_error systemError(const std::string& operation) {
  return std::system_error(errno, std::generic_category(), operation);
}

FileDescriptor::FileDescriptor(int descriptor, FileErrorReporter reporter)
    : descriptor_(descriptor), reporter_(std::move(reporter)) {
  if (descriptor < 0) throw systemError("Open local project resource");
}
FileDescriptor::FileDescriptor(FileDescriptor&& other) noexcept
    : descriptor_(std::exchange(other.descriptor_, -1)), reporter_(std::move(other.reporter_)),
      closeFailure_(std::exchange(other.closeFailure_, nullptr)) {}
FileDescriptor::~FileDescriptor() {
  try { close(); } catch (const std::exception& error) { reporter_(error.what()); }
}
void FileDescriptor::close() {
  if (closeFailure_) std::rethrow_exception(closeFailure_);
  if (descriptor_ < 0) return;
  int descriptor = std::exchange(descriptor_, -1);
  if (::close(descriptor) != 0) {
    closeFailure_ = std::make_exception_ptr(systemError("Close local project descriptor " + std::to_string(descriptor)));
    std::rethrow_exception(closeFailure_);
  }
}

// Copy the potentially-throwing reporter before acquiring any descriptor.
static FileDescriptor openDescriptor(int directory, const std::string& path, int flags, FileErrorReporter reporter) {
  return FileDescriptor(openat(directory, path.c_str(), flags), std::move(reporter));
}

static bool isInside(const fs::path& file, const fs::path& root) {
  auto component = file.begin();
  for (const auto& expected : root) {
    if (component == file.end() || *component++ != expected) return false;
  }
  return component != file.end();
}

ProjectFiles::ProjectFiles(std::string root, FileErrorReporter reporter)
    : requestedRoot_(fs::absolute(root).lexically_normal().string()),
      canonicalRoot_(fs::canonical(requestedRoot_).string()), reporter_(std::move(reporter)),
      root_(openDescriptor(AT_FDCWD, canonicalRoot_, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, reporter_)) {
  struct stat status;
  if (fstat(root_.get(), &status) != 0) throw systemError("Inspect opened project root");
  device_ = status.st_dev; inode_ = status.st_ino;
  verifyIdentity();
}

void ProjectFiles::verifyIdentity() const {
  for (const auto& path : {requestedRoot_, canonicalRoot_}) {
    struct stat status;
    if (::stat(path.c_str(), &status) != 0) throw systemError("Project root unavailable: " + path);
    if (!S_ISDIR(status.st_mode) || status.st_dev != device_ || status.st_ino != inode_)
      throw std::runtime_error("Project root identity changed: " + path);
  }
}

ProjectResource ProjectFiles::open(const std::string& relativePath) const {
  if (relativePath.empty() || relativePath.front() == '/' || relativePath.find('\0') != std::string::npos)
    throw std::runtime_error("Invalid project-relative path");
  for (const auto& component : fs::path(relativePath)) {
    if (component == "..") throw std::runtime_error("Project traversal rejected");
  }
  verifyIdentity();
  const auto resolved = fs::canonical(fs::path(canonicalRoot_) / relativePath);
  if (!isInside(resolved, canonicalRoot_)) throw std::runtime_error("Project symlink escaped root");
  const auto relative = resolved.lexically_relative(canonicalRoot_);
  std::vector<FileDescriptor> ancestors;
  int directory = root_.get();
  // Resolving a symlink is not sufficient: bind every subsequent ancestor open to
  // an already-open directory, rejecting links introduced between resolve and open.
  for (const auto& component : relative.parent_path()) {
    auto ancestor = openDescriptor(directory, component.string(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC, reporter_);
    ancestors.emplace_back(std::move(ancestor));  // Remains owned if vector allocation throws.
    directory = ancestors.back().get();
  }
  auto descriptor = openDescriptor(directory, relative.filename().string(),
      O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, reporter_);
  struct stat status;
  if (fstat(descriptor.get(), &status) != 0) throw systemError("Inspect opened project resource");
  if (!S_ISREG(status.st_mode) || status.st_size < 0) throw std::runtime_error("Project resource is not a regular file");
  char actual[PATH_MAX];
  if (fcntl(descriptor.get(), F_GETPATH, actual) != 0) throw systemError("Inspect opened resource path");
  if (!isInside(fs::path(actual).lexically_normal(), canonicalRoot_))
    throw std::runtime_error("Opened resource moved outside project root");
  verifyIdentity();
  return ProjectResource(std::move(descriptor), status.st_size);
}
}  // namespace dw
