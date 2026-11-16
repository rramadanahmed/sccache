cmake_minimum_required(VERSION 3.20)
project(PublicSeededMsvcPchProbe LANGUAGES CXX)
if(NOT MSVC)
    message(FATAL_ERROR "This public regression probe requires MSVC.")
endif()
if(NOT SCCACHE_EXECUTABLE)
    message(FATAL_ERROR "Set SCCACHE_EXECUTABLE to the fixed sccache.exe.")
endif()
set(CMAKE_MSVC_RUNTIME_LIBRARY MultiThreadedDebugDLL)
set(CMAKE_CXX_FLAGS "/EHsc")
set(CMAKE_CXX_FLAGS_DEBUG "/Zi /Od")
set(CMAKE_EXE_LINKER_FLAGS_DEBUG "/DEBUG /INCREMENTAL:NO")
set(CMAKE_CXX_COMPILE_OBJECT
    "<CMAKE_CXX_COMPILER> <DEFINES> <INCLUDES> <FLAGS> /Fo<OBJECT> /Fd<OBJECT>.pdb /c <SOURCE>")
set(pch "${CMAKE_CURRENT_BINARY_DIR}/group.pch")
set(creator_pdb "${CMAKE_CURRENT_BINARY_DIR}/pch.obj.pdb")
set(seed "${CMAKE_CURRENT_BINARY_DIR}/snapshot.pdb")
set(creator_object "${CMAKE_CURRENT_BINARY_DIR}/pch.obj")
add_custom_command(
    OUTPUT "${pch}" "${creator_pdb}" "${creator_object}"
    COMMAND "${CMAKE_COMMAND}" -E env SCCACHE_MSVC_PRIVATE_PDB=1
        "${SCCACHE_EXECUTABLE}" "${CMAKE_CXX_COMPILER}"
        /nologo /c /MDd /Od /Zi /EHsc /D_ITERATOR_DEBUG_LEVEL=2
        /Ycpch.h "/Fp${pch}" "/Fd${creator_pdb}" "/Fo${creator_object}"
        "${CMAKE_CURRENT_SOURCE_DIR}/pch.cpp"
    DEPENDS pch.cpp pch.h
    VERBATIM)
add_custom_command(
    OUTPUT "${seed}"
    COMMAND "${CMAKE_COMMAND}" -E copy_if_different "${creator_pdb}" "${seed}"
    DEPENDS "${creator_pdb}" "${pch}" "${creator_object}"
    VERBATIM)
set_source_files_properties("${creator_object}" PROPERTIES GENERATED TRUE EXTERNAL_OBJECT TRUE)
set_source_files_properties(seed-a.cpp seed-b.cpp PROPERTIES OBJECT_DEPENDS "${pch};${seed}")
add_executable(public_seeded_probe seed-a.cpp seed-b.cpp "${creator_object}")
target_compile_options(public_seeded_probe PRIVATE
    /EHsc /Yupch.h "/Fp${pch}" /D_ITERATOR_DEBUG_LEVEL=2)
set_property(TARGET public_seeded_probe PROPERTY CXX_COMPILER_LAUNCHER
    "${CMAKE_COMMAND};-E;env;SCCACHE_MSVC_PRIVATE_PDB=1;SCCACHE_MSVC_PCH_SOURCE_DEPENDENCIES=1;SCCACHE_MSVC_PCH_PDB=${seed};${SCCACHE_EXECUTABLE}")
target_link_options(public_seeded_probe PRIVATE "/PDB:${CMAKE_CURRENT_BINARY_DIR}/link.pdb")
