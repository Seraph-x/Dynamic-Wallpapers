#pragma once
#include <cstdint>
#include <functional>
#include <exception>
#include <string>
#include <sys/types.h>
#include <utility>
#include <vector>

namespace dw {
using FileErrorReporter = std::function<void(const std::string&)>;

/// Move-only descriptor. Explicit close throws; destructor failures reach the owner.
/// Never retry close after an ambiguous OS error, which could close a reused descriptor.
class FileDescriptor final {
 public:
  FileDescriptor(int descriptor, FileErrorReporter reporter);
  FileDescriptor(FileDescriptor&& other) noexcept;
  FileDescriptor(const FileDescriptor&) = delete;
  FileDescriptor& operator=(const FileDescriptor&) = delete;
  ~FileDescriptor();
  int get() const { return descriptor_; }
  void close();
 private:
  int descriptor_;
  FileErrorReporter reporter_;
  std::exception_ptr closeFailure_;
};

class ProjectResource final {
 public:
  ProjectResource(FileDescriptor file, int64_t size) : file_(std::move(file)), size_(size) {}
  int descriptor() const { return file_.get(); }
  int64_t size() const { return size_; }
  void close() { file_.close(); }
 private:
  FileDescriptor file_;
  int64_t size_;
};

/// One project identity, not a path that silently adopts a replacement directory.
/// Returned resources are opened relative to the bound directory descriptor.
class ProjectFiles final {
 public:
  ProjectFiles(std::string root, FileErrorReporter reporter);
  ProjectResource open(const std::string& relativePath) const;
  void verifyIdentity() const;
 private:
  const std::string requestedRoot_;
  const std::string canonicalRoot_;
  FileErrorReporter reporter_;
  FileDescriptor root_;
  dev_t device_;
  ino_t inode_;
};
}  // namespace dw
