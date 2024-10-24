#include "glslang/Include/glslang_c_interface.h"
#include "glslang/Public/resource_limits_c.h"
#include <iostream>


int main(void)
{
    std::cout << "Initialize process" << std::endl;

    glslang_initialize_process();

    std::cout << "Initialized process" << std::endl;

    glslang_stage_t stage = GLSLANG_STAGE_FRAGMENT;

    const char* fileName = u8"ExampleShader.hlsl";

    const char* shaderSource = u8R"(
struct VertexInput
{
    float2 Position : POSITION;
    float4 Color : COLOR0;
};

struct VertexOutput
{
    float4 Position : SV_POSITION;
    float4 Color : COLOR0;
};


VertexOutput vertex(VertexInput input)
{
    VertexOutput output;
    output.Position = float4(input.Position, 0, 1);
    output.Color = input.Color;
    return output;
}

#define DO_SOMETHING(x) x * 10 + 4 - 8 + sqrt(x) / abs(x)


float4 pixel(VertexOutput input) : SV_Target
{
    float value = DO_SOMETHING(input.Color.r);

    float value2 = DO_SOMETHING(value);

    float value3 = DO_SOMETHING(value2);

    input.Color *= 10;

    input.Color /= 43.55;

    input.Color.g = value2;
    input.Color.b = value;
    input.Color.a = value3;

    return input.Color;
}
    )";

    const glslang_input_t input = {
        .language = GLSLANG_SOURCE_HLSL,
        .stage = stage,
        .client = GLSLANG_CLIENT_VULKAN,
        .client_version = GLSLANG_TARGET_VULKAN_1_2,
        .target_language = GLSLANG_TARGET_SPV,
        .target_language_version = GLSLANG_TARGET_SPV_1_5,
        .code = shaderSource,
        .entrypoint = "main",
        .source_entrypoint = "pixel",
        .default_version = 100,
        .default_profile = GLSLANG_NO_PROFILE,
        .force_default_version_and_profile = false,
        .forward_compatible = false,
        .messages = GLSLANG_MSG_DEFAULT_BIT,
        .resource = glslang_default_resource(),
    };

    std::cout << "Setup default resource" << std::endl;

    glslang_shader_t* shader = glslang_shader_create(&input);

    std::cout << "Created shader" << std::endl;

    if (!glslang_shader_preprocess(shader, &input))	{
        printf("HLSL preprocessing failed %s\n", fileName);
        printf("%s\n", glslang_shader_get_info_log(shader));
        printf("%s\n", glslang_shader_get_info_debug_log(shader));
        printf("%s\n", input.code);
        glslang_shader_delete(shader);
        return 1;
    }

    std::cout << "Preprocessed shader" << std::endl;

    if (!glslang_shader_parse(shader, &input)) {
        printf("HLSL parsing failed %s\n", fileName);
        printf("%s\n", glslang_shader_get_info_log(shader));
        printf("%s\n", glslang_shader_get_info_debug_log(shader));
        printf("%s\n", glslang_shader_get_preprocessed_code(shader));
        glslang_shader_delete(shader);
        glslang_finalize_process();
        return 1;
    }

    std::cout << "Parsed shader" << std::endl;

    glslang_program_t* program = glslang_program_create();

    std::cout << "Created program" << std::endl;

    glslang_program_add_shader(program, shader);

    std::cout << "Add shader to program" << std::endl;

    if (!glslang_program_link(program, GLSLANG_MSG_SPV_RULES_BIT | GLSLANG_MSG_VULKAN_RULES_BIT)) {
        printf("HLSL linking failed %s\n", fileName);
        printf("%s\n", glslang_program_get_info_log(program));
        printf("%s\n", glslang_program_get_info_debug_log(program));
        glslang_program_delete(program);
        glslang_shader_delete(shader);
        glslang_finalize_process();
        return 1;
    }

    std::cout << "Linked program" << std::endl;

    glslang_program_SPIRV_generate(program, stage);
    
    std::cout << "Generate SPIRV" << std::endl;

    size_t size = glslang_program_SPIRV_get_size(program);
    uint32_t* words = static_cast<uint32_t*>(malloc(size * sizeof(uint32_t)));
    glslang_program_SPIRV_get(program, words);

    std::cout << "Got SPIRV" << std::endl;

    const char* spirv_messages = glslang_program_SPIRV_get_messages(program);
    if (spirv_messages)
        printf("(%s) %s\b", fileName, spirv_messages);

    std::cout << "Got messages" << std::endl;

    glslang_program_delete(program);
    glslang_shader_delete(shader);

    std::cout << "Free program and shader" << std::endl;

    char* disassembled = glslang_SPIRV_disassemble(words, size);

    std::cout << "Disassemble SPIRV" << std::endl;

    std::cout << "Generated " << size << " SPIR-V words" << std::endl;
    std::cout << disassembled << std::endl;

    free(disassembled);
    free(words);

    glslang_finalize_process();
}