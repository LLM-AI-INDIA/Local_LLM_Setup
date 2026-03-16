"""Test streaming from vLLM LLaMA 3.1 8B endpoint."""

import os
import sys
from openai import OpenAI

NLB_URL = os.getenv("VLLM_ENDPOINT", "http://localhost:8000/v1")
MODEL = os.getenv("VLLM_MODEL", "meta-llama/Llama-3.1-8B-Instruct")

client = OpenAI(base_url=NLB_URL, api_key="not-needed")

while True:
    try:
        prompt = input("\nEnter your prompt (type 'exit' or 'stop' to quit): ").strip()
    except (EOFError, KeyboardInterrupt):
        print("\nGoodbye!")
        break

    if not prompt:
        continue
    if prompt.lower() in ("exit", "stop"):
        print("Goodbye!")
        break

    print(f"\n> {prompt}\n")

    stream = client.chat.completions.create(
        model=MODEL,
        messages=[{"role": "user", "content": prompt}],
        stream=True,
        max_tokens=512,
    )

    for chunk in stream:
        content = chunk.choices[0].delta.content
        if content:
            print(content, end="", flush=True)

    print("\n")
