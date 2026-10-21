#include "LocalProjectFiles.hpp"
#include <filesystem>
#include <cerrno>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <sys/stat.h>
#include <unistd.h>

namespace fs = std::filesystem;

static void require(bool value, const char* message) {
  if (!value) throw std::runtime_error(message);
}

template<class Operation> static void rejects(Operation operation, const char* message) {
  bool rejected = false;
  try { operation(); } catch (const std::exception&) { rejected = true; }
  require(rejected, message);
}

static std::string read(dw::ProjectFiles& project, const std::string& name) {
  auto file = project.open(name);
  std::string result;
  char bytes[64];
  ssize_t count;
  while ((count = ::read(file.descriptor(), bytes, sizeof(bytes))) > 0) result.append(bytes, count);
  require(count == 0, "resource read failed");
  require(static_cast<int64_t>(result.size()) == file.size(), "resource size mismatch");
  file.close();
  return result;
}

struct ReporterCopies { bool fail = false; std::vector<std::string> errors; };
struct ThrowingReporter {
  std::shared_ptr<ReporterCopies> copies;
  explicit ThrowingReporter(std::shared_ptr<ReporterCopies> copies) : copies(std::move(copies)) {}
  ThrowingReporter(const ThrowingReporter& other) : copies(other.copies) {
    if (copies->fail) throw std::runtime_error("controlled reporter-copy failure");
  }
  void operator()(const std::string& message) const { copies->errors.push_back(message); }
};

static int descriptorCount() {
  int count = 0;
  for (int descriptor = 0; descriptor < getdtablesize(); ++descriptor) {
    if (fcntl(descriptor, F_GETFD) >= 0) ++count;
    else require(errno == EBADF, "descriptor enumeration failed");
  }
  return count;
}

int main(int argc, char** argv) {
  try {
    require(argc == 2, "usage: project-files-test OUTPUT_DIRECTORY");
    fs::path base(argv[1]), root = base / "project", adjacent = base / "project-other";
    fs::create_directories(root / "assets");
    fs::create_directory(adjacent);
    std::ofstream(root / "index.html") << "local-page";
    std::ofstream(root / "assets" / "中文 + %.mjs") << "local-module";
    std::ofstream(adjacent / "outside.txt") << "outside-project";
    fs::create_symlink(root / "assets" / "中文 + %.mjs", root / "inside.mjs");
    fs::create_symlink(adjacent / "outside.txt", root / "outside.txt");
    fs::create_directory_symlink(adjacent, root / "outside-directory");
    require(mkfifo((root / "pipe").c_str(), 0600) == 0, "mkfifo failed");
    std::vector<std::string> cleanupErrors;
    {
      auto copies = std::make_shared<ReporterCopies>();
      dw::ProjectFiles project(root.string(), ThrowingReporter(copies));
      const int before = descriptorCount();
      copies->fail = true;
      rejects([&] { (void)project.open("assets/中文 + %.mjs"); }, "reporter copy fault was not injected");
      copies->fail = false;
      require(descriptorCount() == before, "descriptor leaked before RAII ownership during reporter copy");
      require(copies->errors.empty(), "unexpected descriptor cleanup error");
    }
    {
      dw::ProjectFiles project(root.string(), [&](const std::string& message) { cleanupErrors.push_back(message); });
      require(read(project, "index.html") == "local-page", "local file not readable");
      require(read(project, "assets/中文 + %.mjs") == "local-module", "Unicode/space/plus/percent path changed");
      require(read(project, "inside.mjs") == "local-module", "in-project symlink not supported");
      for (const auto& path : {"../project-other/outside.txt", "/index.html", "outside.txt",
                               "outside-directory/outside.txt", "assets", "pipe", "missing.html"}) {
        rejects([&] { (void)project.open(path); }, "invalid resource was accepted");
      }
      rejects([&] { (void)project.open(std::string("index.html\0tail", 15)); }, "NUL resource was accepted");
      fs::remove(root / "inside.mjs");
      fs::create_symlink(adjacent / "outside.txt", root / "inside.mjs");
      rejects([&] { (void)project.open("inside.mjs"); }, "changed symlink escaped root");
      fs::rename(root, base / "original-project");
      fs::create_directory(root);
      std::ofstream(root / "index.html") << "replacement";
      rejects([&] { (void)project.open("index.html"); }, "replaced project root was silently adopted");
    }
    require(cleanupErrors.empty(), "file cleanup errors were recorded");
    std::vector<std::string> failedCloses;
    {
      int descriptor = ::open((base / "original-project/index.html").c_str(), O_RDONLY);
      require(descriptor >= 0, "open close-failure fixture failed");
      dw::FileDescriptor file(descriptor, [&](const std::string& message) { failedCloses.push_back(message); });
      require(::close(descriptor) == 0, "controlled descriptor invalidation failed");
      rejects([&] { file.close(); }, "invalidated descriptor close must fail");
      rejects([&] { file.close(); }, "earlier close error was converted into later success");
    }
    require(failedCloses.size() == 1, "unresolved close failure must remain observable on destruction");
    std::cout << "PROJECT_FILES passed local/unicode/internal-link/outside-link/traversal/nonregular/root-identity/close-error/copy-fault\n";
    return 0;
  } catch (const std::exception& error) {
    std::cerr << "PROJECT_FILES ERROR " << error.what() << '\n';
    return 1;
  }
}
