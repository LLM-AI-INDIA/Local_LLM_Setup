import { createOpenAICompatible } from '@ai-sdk/openai-compatible';
import { wrapLanguageModel } from 'ai';

export const VLLM_MODEL_ID = 'meta-llama/Llama-3.1-8B-Instruct';

const vllmProvider = createOpenAICompatible({
  name: 'vllm',
  baseURL: process.env.VLLM_BASE_URL || 'http://localhost:8000/v1',
  apiKey: 'not-needed',
});

/**
 * Middleware that limits tool calls to 1 per turn.
 * vLLM/Llama only supports single tool calls — if the model generates multiple,
 * we keep only the first one to prevent "single tool-calls at once" errors.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const singleToolCallMiddleware: any = {
  specificationVersion: 'v3',
  wrapGenerate: async ({ doGenerate }: { doGenerate: () => Promise<Record<string, unknown>> }) => {
    const result = await doGenerate();
    // Filter content array to keep only the first tool-call
    if (Array.isArray(result.content)) {
      let toolCallFound = false;
      result.content = result.content.filter((part: { type?: string }) => {
        if (part.type === 'tool-call') {
          if (toolCallFound) return false; // Drop subsequent tool calls
          toolCallFound = true;
        }
        return true;
      });
    }
    return result;
  },
  wrapStream: async ({ doStream }: { doStream: () => Promise<{ stream: ReadableStream; [key: string]: unknown }> }) => {
    const { stream, ...rest } = await doStream();
    let firstToolCallIndex = -1;
    const transformedStream = stream.pipeThrough(
      new TransformStream({
        transform(chunk: { type?: string; toolCallIndex?: number; [key: string]: unknown }, controller) {
          if (chunk.type === 'tool-call-delta') {
            const idx = chunk.toolCallIndex ?? 0;
            if (firstToolCallIndex === -1) firstToolCallIndex = idx;
            if (idx !== firstToolCallIndex) return; // Drop other tool call deltas
          }
          if (chunk.type === 'tool-call') {
            const idx = chunk.toolCallIndex ?? 0;
            if (firstToolCallIndex === -1) firstToolCallIndex = idx;
            if (idx !== firstToolCallIndex) return; // Drop other tool calls
          }
          controller.enqueue(chunk);
        },
      })
    );
    return { stream: transformedStream, ...rest };
  },
};

/**
 * Wraps vLLM model with single-tool-call middleware.
 * Usage: vllm(modelId) returns a model that only allows 1 tool call per turn.
 */
export function vllm(modelId: string) {
  return wrapLanguageModel({
    model: vllmProvider(modelId),
    middleware: singleToolCallMiddleware,
  });
}

export function isVLLMModel(modelId: string): boolean {
  return modelId.startsWith('meta-llama/');
}
