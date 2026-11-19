# Mayhem build of Tracy's server library + tools, offline.
#
# Same structure as upstream's csvexport/ and import/ projects (cmake/config.cmake +
# cmake/server.cmake), except that cmake/vendor.cmake — which downloads capstone, zstd, PPQSort and
# nlohmann/json with CPM at configure time — is replaced by the same dependencies prebuilt into the
# image under /opt/toolchains/deps (mayhem/Dockerfile), so the build never touches the network.
#
#   MAYHEM_FUZZ=ON   libFuzzer harnesses (mayhem/fuzz/*.cpp) — compile flags come from the caller
#   MAYHEM_BACKTRACE=ON  backtrace_elf: file-input harness over public/libbacktrace
#   MAYHEM_TOOLS=ON  upstream's tracy-import-chrome, tracy-import-fuchsia and tracy-csvexport
cmake_minimum_required(VERSION 3.16)

set(NO_STATISTICS OFF)
set(NO_ISA_EXTENSIONS ON CACHE BOOL "" FORCE)
set(NO_LTO ON CACHE BOOL "" FORCE)
set(NO_MOLD_LINKER ON CACHE BOOL "" FORCE)
set(NO_CCACHE ON CACHE BOOL "" FORCE)

set(TRACY_ROOT ${CMAKE_CURRENT_LIST_DIR}/../..)
include(${TRACY_ROOT}/cmake/version.cmake)

set(CMAKE_CXX_STANDARD 20)
project(tracy-mayhem LANGUAGES C CXX VERSION ${TRACY_VERSION_STRING})

option(MAYHEM_FUZZ "Build the libFuzzer harnesses" OFF)
option(MAYHEM_TOOLS "Build the upstream CLI tools" OFF)
option(MAYHEM_BACKTRACE "Build the libbacktrace ELF/DWARF file-input harness" OFF)

include(${TRACY_ROOT}/cmake/config.cmake)

# mayhem/lsan_off.cc (__lsan_is_turned_off), linked into every ASan harness; build.sh passes it.
set(LSAN_OFF "" CACHE FILEPATH "LeakSanitizer off-switch TU")

set(DEPS /opt/toolchains/deps)
find_package(Threads REQUIRED)

add_library(TracyCapstone INTERFACE)
target_include_directories(TracyCapstone INTERFACE ${DEPS}/capstone-6.0.0-Alpha11/include/capstone)
target_link_libraries(TracyCapstone INTERFACE ${DEPS}/capstone-6.0.0-Alpha11/lib/libcapstone.a)

# zstd 1.5.7 (upstream's pinned version) is Debian's libzstd-dev in the base image.
add_library(libzstd INTERFACE)
target_link_libraries(libzstd INTERFACE /usr/lib/x86_64-linux-gnu/libzstd.a)

add_library(PPQSort INTERFACE)
target_include_directories(PPQSort INTERFACE ${DEPS}/PPQSort-1.0.6/src/include)
target_link_libraries(PPQSort INTERFACE Threads::Threads)
add_library(PPQSort::PPQSort ALIAS PPQSort)

add_library(nlohmann_json INTERFACE)
target_include_directories(nlohmann_json INTERFACE ${DEPS}/json-3.12.0/src/include)
add_library(nlohmann_json::nlohmann_json ALIAS nlohmann_json)

add_library(TracyGetOpt STATIC EXCLUDE_FROM_ALL ${TRACY_ROOT}/getopt/getopt.c)
target_include_directories(TracyGetOpt PUBLIC ${TRACY_ROOT}/getopt)

include(${TRACY_ROOT}/cmake/server.cmake)

if(MAYHEM_TOOLS)
    # GitRef.hpp as cmake/GitRef.cmake generates it, without calling git.
    file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/GitRef.hpp
        "#pragma once\nnamespace tracy { static inline const char* GitRef = \"mayhem\"; }\n")
    add_executable(tracy-import-chrome ${TRACY_ROOT}/import/src/import-chrome.cpp)
    target_link_libraries(tracy-import-chrome PRIVATE TracyServer nlohmann_json::nlohmann_json)
    add_executable(tracy-import-fuchsia ${TRACY_ROOT}/import/src/import-fuchsia.cpp)
    target_link_libraries(tracy-import-fuchsia PRIVATE TracyServer)
    add_executable(tracy-csvexport ${TRACY_ROOT}/csvexport/src/csvexport.cpp)
    target_link_libraries(tracy-csvexport PRIVATE TracyServer TracyGetOpt)
    foreach(t tracy-import-chrome tracy-import-fuchsia tracy-csvexport)
        target_include_directories(${t} PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
        if(LSAN_OFF)
            target_sources(${t} PRIVATE ${LSAN_OFF})
        endif()
    endforeach()
endif()

if(MAYHEM_BACKTRACE)
    # Tracy's bundled libbacktrace, as compiled into the client on Linux (macho.cpp is Apple-only).
    # Without TRACY_ENABLE its tracy_malloc/tracy_free are plain malloc/free (common/TracyAlloc.hpp).
    set(BT ${TRACY_ROOT}/public/libbacktrace)
    add_executable(backtrace_elf ${CMAKE_CURRENT_LIST_DIR}/backtrace_elf.cpp
        ${BT}/alloc.cpp ${BT}/dwarf.cpp ${BT}/elf.cpp ${BT}/fileline.cpp ${BT}/mmapio.cpp
        ${BT}/posix.cpp ${BT}/sort.cpp ${BT}/state.cpp ${LSAN_OFF})
endif()

if(MAYHEM_FUZZ)
    # LIB_FUZZING_ENGINE / STANDALONE_FUZZ_MAIN come from the base image's build contract.
    add_library(standalone_main OBJECT $ENV{STANDALONE_FUZZ_MAIN})
    set_source_files_properties($ENV{STANDALONE_FUZZ_MAIN} PROPERTIES LANGUAGE C)
    function(mayhem_fuzzer name src)
        add_executable(${name} ${src} ${LSAN_OFF})
        target_link_libraries(${name} PRIVATE TracyServer)
        target_link_options(${name} PRIVATE $ENV{LIB_FUZZING_ENGINE})
        target_compile_definitions(${name} PRIVATE ${ARGN})
        add_executable(${name}-standalone ${src} ${LSAN_OFF} $<TARGET_OBJECTS:standalone_main>)
        target_link_libraries(${name}-standalone PRIVATE TracyServer)
        target_compile_definitions(${name}-standalone PRIVATE ${ARGN})
    endfunction()
    mayhem_fuzzer(fuzz_trace_load ${CMAKE_CURRENT_LIST_DIR}/fuzz_trace_load.cpp)
    mayhem_fuzzer(fuzz_trace_write ${CMAKE_CURRENT_LIST_DIR}/fuzz_trace_load.cpp TRACE_WRITE)
    mayhem_fuzzer(fuzz_broadcast ${CMAKE_CURRENT_LIST_DIR}/fuzz_broadcast.cpp)
endif()
