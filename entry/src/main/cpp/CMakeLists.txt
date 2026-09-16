# HX360E 原生构建
#
# Phase 0 spike：JIT 四策略探测 + Vulkan(OHOS surface) 清屏呈现。
# Phase 1：接入 XenDroid/Xenia 内核（源码树在 XE_XENDROID_ROOT），
#          先用 null GPU 后端跑通「编译链接 + dlopen + 加载 XEX」，
#          Vulkan 后端在 Phase 2 接入。
cmake_minimum_required(VERSION 3.20)
project(hx360e LANGUAGES C CXX ASM)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
# xenia 不使用 C++20 modules，关闭 Ninja 的逐目标 dyndep 扫描。
set(CMAKE_CXX_SCAN_FOR_MODULES OFF)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

# OHOS 平台宏：让 xenia 的 platform.h 走 __OHOS__ 分支（复用 xendroid +
# POSIX 代码路径）。xenia 的 CMake 源文件选择也依赖 OHOS 变量。
add_compile_definitions(OHOS=1 __OHOS__=1)

# 与上游 XenDroid 一致的保守编译选项；不使用 -stdlib=libc++（OHOS 自带）。
add_compile_options(-march=armv8-a)
add_compile_options(-fno-omit-frame-pointer)
add_compile_options(-funwind-tables)

# 上游 XenDroid 的 xenia 源码树（本地 fork，含 harmony 补丁）。
# 通过缓存变量指定，便于换用其它 fork / 子模块路径。
set(XE_XENDROID_ROOT "D:/Code/OpenSource/XenDroid/emulator-core/src/main/cpp"
    CACHE PATH "XenDroid xenia source root")

# 关闭 ThinLTO：OHOS 工具链默认不带 lld，Release 下 -flto=thin -fuse-ld=lld 会失败。
set(XENIA_ENABLE_LTO OFF CACHE BOOL "" FORCE)

# XEngine Kit（Maleoon GPU 加速）头文件：从编译器路径反推 hms SDK（<hms>/native/BiSheng/bin），
# 只加 include 目录，运行时用 dlopen("libxengine.so")，不硬链接 —— 保证在非
# Maleoon / 非中国区设备上 libentry.so 仍能正常加载。找不到头文件就跳过（走本地声明兜底）。
get_filename_component(_hx360e_compiler_dir "${CMAKE_CXX_COMPILER}" DIRECTORY)
get_filename_component(_hx360e_xengine_include
    "${_hx360e_compiler_dir}/../../../native/sysroot/usr/include" ABSOLUTE)
if(EXISTS "${_hx360e_xengine_include}/xengine/xeg_vulkan_extension.h")
    set(HX360E_XENGINE_INCLUDE_DIR "${_hx360e_xengine_include}")
    add_compile_definitions(HX360E_HAVE_XENGINE_HEADERS=1)
    # 全局 include：xenia 侧的 vulkan_presenter 也要 include 这个头（经由我们的
    # xeg_spatial_upscale.h），所以不能只挂在 entry 目标上。
    include_directories("${_hx360e_xengine_include}")
    message(STATUS "XEngine headers: ${_hx360e_xengine_include}")
else()
    message(STATUS "XEngine headers not found, using local ABI declarations")
endif()

# EXCLUDE_FROM_ALL：只构建被 entry 依赖的目标，不编译桌面端 xenia-app 等。
# HX360E：xenia 侧有少量文件会 include 本移植目录下的头文件（如 XEngine 空域
# 超分封装 xeg_spatial_upscale.h），所以在这里先把本目录加进 include 路径，
# 让 xenia 的目标也能找到（否则只对 entry 目标可见）。
include_directories(${NATIVERENDER_ROOT_PATH})
add_subdirectory("${XE_XENDROID_ROOT}/xenia"
    "${CMAKE_CURRENT_BINARY_DIR}/xendroid-build" EXCLUDE_FROM_ALL)

include_directories(${NATIVERENDER_ROOT_PATH})

add_library(entry SHARED
        napi_init.cpp
        jit_probe.cpp
        vulkan_context.cpp
        xeg_spatial_upscale.cc
        xendroid_ohos/ohos_emulator.cc
        xendroid_ohos/napi_zip.cc
        xendroid_ohos/zip_extract.cc
        xendroid_ohos/ohos_input_driver.cc
        xendroid_ohos/ohos_window.cc
        xendroid_ohos/ohaudio_audio_driver.cc
        xendroid_ohos/ohaudio_audio_system.cc
        xendroid_ohos/napi_config.cc
        xendroid_ohos/napi_meta.cc
        xendroid_ohos/napi_prompt.cc
        xendroid_ohos/napi_content.cc
        xendroid_ohos/prompt_providers.cc
        xendroid_ohos/file_picker_ohos.cc
        xendroid_ohos/system_ohos.cc
)

# xenia 头文件（静态库的 include 目录是 PRIVATE，不会传播到 entry）。
target_include_directories(entry PRIVATE
        "${XE_XENDROID_ROOT}/xenia"
        "${XE_XENDROID_ROOT}/xenia/src"
        "${XE_XENDROID_ROOT}/xenia/third_party"
)

if(HX360E_XENGINE_INCLUDE_DIR)
    target_include_directories(entry PRIVATE "${HX360E_XENGINE_INCLUDE_DIR}")
endif()

target_link_libraries(entry PUBLIC
        libace_napi.z.so
        libace_ndk.z.so
        libnative_window.so
        libnative_vsync.so
        libvulkan.so
        libhilog_ndk.z.so
        # OHAudio（Phase 3 音频驱动）。libohaudio.so 由系统提供。
        libohaudio.so
        # GameControllerKit（物理手柄，OHOS API 21+）。设备不支持时注册函数
        # 返回错误码，不影响启动。
        libohgame_controller.z.so

        # ---- XenDroid / Xenia 内核（Phase 1：null GPU 后端）----
        xenia-apu
        xenia-apu-nop
        xenia-base
        xenia-core
        xenia-cpu
        xenia-cpu-backend-a64
        xenia-gpu
        xenia-gpu-null
        xenia-gpu-vulkan
        xenia-hid
        xenia-hid-nop
        xenia-kernel
        xenia-patcher
        xenia-ui
        xenia-vfs

        # 上游只在 xenia-app 里链接 imgui，HX360E 不编译 app，故显式补上。
        imgui

        dl
        z
)

# 只导出 NAPI 入口符号。
target_link_options(entry PRIVATE -Wl,--exclude-libs,ALL)
