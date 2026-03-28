# 图像生成参考

本文根据 MiniMax 开放平台官方文档整理，覆盖图像生成能力的入口、模型、请求示例和常见使用方式。

来源：

- [API 概览](https://platform.minimaxi.com/docs/api-reference/api-overview)
- [图像生成（Image Generation）](https://platform.minimaxi.com/docs/api-reference/image-generation-intro)

## 能力概述

图像生成服务提供文生图（text-to-image）与图生图（image-to-image）两种核心功能。

它支持基于详尽文本描述直接生成图片，也支持提供一张或多张参考图，在保留主体特征的前提下生成新的创意图像。接口同时支持设置图片比例和长宽像素，以适配不同场景。

## 模型列表

| 模型          | 说明                                                           |
| ------------- | -------------------------------------------------------------- |
| image-01      | 图像生成模型，画面表现细腻，支持文生图和图生图（人物主体参考） |
| image-01-live | 在 image-01 基础上额外支持多种画风设置                         |

## 使用流程

官方页面描述的基本流程是通过创建图片生成任务接口，使用文本描述和参考图片发起生成。

1. 选择模型，通常是 `image-01` 或 `image-01-live`。
2. 准备 prompt，尽量写清主体、场景、风格、光照、镜头和构图。
3. 如果需要图生图，提供一张或多张主体清晰的参考图。
4. 选择输出格式，常见是 `base64`，也可以按接口能力选择 URL 类结果。
5. 提交任务并处理返回的图片数据。

### 根据文本生成图片

这是最常见的用法，适合快速生成配图、概念图和海报草稿。官方示例使用 `image-01`，并指定 `aspect_ratio` 与 `response_format`。

```python
import base64
import requests
import os

url = "https://api.minimaxi.com/v1/image_generation"
api_key = os.environ.get("MINIMAX_API_KEY")
headers = {"Authorization": f"Bearer {api_key}"}

payload = {
    "model": "image-01",
    "prompt": "men Dressing in white t shirt, full-body stand front view image :25, outdoor, Venice beach sign, full-body image, Los Angeles, Fashion photography of 90s, documentary, Film grain, photorealistic",
    "aspect_ratio": "16:9",
    "response_format": "base64",
}

response = requests.post(url, headers=headers, json=payload)
response.raise_for_status()

images = response.json()["data"]["image_base64"]

for i in range(len(images)):
    with open(f"output-{i}.jpeg", "wb") as f:
        f.write(base64.b64decode(images[i]))
```

### 结合参考图生成图片

这个模式适合保持人物、角色或主体一致性，再生成不同场景下的新图片。官方示例通过 `subject_reference` 传入参考图，并在 prompt 中描述目标场景。

```python
import base64
import requests
import os

url = "https://api.minimaxi.com/v1/image_generation"
api_key = os.environ.get("MINIMAX_API_KEY")
headers = {"Authorization": f"Bearer {api_key}"}

payload = {
    "model": "image-01",
    "prompt": "女孩在图书馆的窗户前，看向远方",
    "aspect_ratio": "16:9",
    "subject_reference": [
        {
            "type": "character",
            "image_file": "https://cdn.hailuoai.com/prod/2025-08-12-17/video_cover/1754990600020238321-411603868533342214-cover.jpg",
        }
    ],
    "response_format": "base64",
}

response = requests.post(url, headers=headers, json=payload)
response.raise_for_status()
images = response.json()["data"]["image_base64"]

for i in range(len(images)):
    with open(f"output-{i}.jpeg", "wb") as f:
        f.write(base64.b64decode(images[i]))
```

## 适合的场景

- 基于文字描述生成创意配图。
- 基于参考图片生成变体或延展内容。
- 需要控制画面比例和输出尺寸的图像任务。

## 使用建议

- prompt 尽量具体，明确主体、动作、环境、风格和画面关系。
- 参考图最好主体清晰、无遮挡，这样更有利于保留特征。
- 如果目标是快速调试，优先使用 `base64`，便于直接落盘或后处理。
- 如果目标是批量产出，建议先固定模型、比例和 prompt 模板，再逐步调整参考图。

## 说明

这份整理页用于本地快速查阅。若需要最新的请求参数、任务字段和返回示例，请以官方页面为准。
