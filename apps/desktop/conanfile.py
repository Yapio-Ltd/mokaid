from conan import ConanFile
from conan.tools.cmake import cmake_layout, CMakeToolchain


class MokaidDesktop(ConanFile):
    name = "mokaid-desktop"
    version = "0.1.0"
    settings = "os", "compiler", "build_type", "arch"
    # Qt is an exact, separately verified SDK. No source-unlocked native
    # dependencies are injected by Conan; the asset cooker has its own lockfile.
    def layout(self):
        cmake_layout(self)

    def generate(self):
        CMakeToolchain(self).generate()
