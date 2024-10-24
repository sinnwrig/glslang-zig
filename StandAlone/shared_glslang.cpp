#include "glslang/Include/glslang_c_interface.h"
#include "glslang/Public/resource_limits_c.h"
#include <iostream>


int main(void)
{
    // Weird issue, proobably a bad config glslang won't export the right definitions 
    // unless we explicitly reference them when creating this shared library
    // Seems like it's 'per-module' though (whatever that means), since we don't need to define every function and just core SPIRV/resource/glslang functions
    glslang_initialize_process();
    glslang_default_resource();
    glslang_SPIRV_disassemble(nullptr, 0);
    glslang_finalize_process();
}