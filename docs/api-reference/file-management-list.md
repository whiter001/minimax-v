# 文件管理 - 文件列出参考

本文根据 MiniMax 开放平台官方文档整理，覆盖文件列出接口的用途、鉴权、请求参数和返回结构，方便本地快速查阅。

来源：

- [文件列出](https://platform.minimaxi.com/docs/api-reference/file-management-list)
- [文件上传](https://platform.minimaxi.com/docs/api-reference/file-management-upload)
- [文件检索](https://platform.minimaxi.com/docs/api-reference/file-management-retrieve)

## 能力概述

文件列出接口用于按文件用途分类查看已上传文件。它通常和文件上传、文件检索接口配合使用，用来在语音复刻、长文本语音生成等流程中管理输入文件和中间文件。

## 接口信息

```http
GET /v1/files/list
```

### 示例请求

```bash
curl --request GET \
  --url https://api.minimaxi.com/v1/files/list \
  --header 'Authorization: Bearer <token>'
```

## 鉴权

该接口使用 `Authorization` 请求头进行 Bearer 鉴权。

```http
Authorization: Bearer <API_key>
```

API Key 可在官方控制台的接口密钥页面查看。

## 查询参数

### `purpose` `enum<string>` 必填

用于指定要列出的文件分类。官方页面展示的可选值如下：

- `voice_clone`：快速复刻原始文件
- `prompt_audio`：音色复刻的示例音频
- `t2a_async_input`：异步长文本语音生成合成中音频

> 说明：官方页面的说明文字中有时会写作 `t2a_async`，但示例和可选值显示为 `t2a_async_input`。实际调用时建议以接口返回和官方示例为准。

## 响应结构

### 成功响应

接口返回 `200 application/json`，响应体包含文件列表和基础返回信息。

```json
{
  "files": [
    {
      "file_id": "${file_id}",
      "bytes": 5896337,
      "created_at": 1699964873,
      "filename": "297990555456011.tar",
      "purpose": "t2a_async_input"
    },
    {
      "file_id": "${file_id}",
      "bytes": 5896337,
      "created_at": 1700469398,
      "filename": "297990555456911.tar",
      "purpose": "t2a_async_input"
    }
  ],
  "base_resp": {
    "status_code": 0,
    "status_msg": "success"
  }
}
```

### 字段说明

| 字段                    | 类型       | 说明               |
| ----------------------- | ---------- | ------------------ |
| `files`                 | `object[]` | 文件列表           |
| `files[].file_id`       | `string`   | 文件标识           |
| `files[].bytes`         | `number`   | 文件大小，单位字节 |
| `files[].created_at`    | `number`   | 创建时间戳         |
| `files[].filename`      | `string`   | 原始文件名         |
| `files[].purpose`       | `string`   | 文件用途分类       |
| `base_resp.status_code` | `number`   | 基础状态码         |
| `base_resp.status_msg`  | `string`   | 基础状态信息       |

## 使用流程

1. 先按用途上传文件。
2. 调用文件列出接口确认文件是否存在。
3. 拿到 `file_id` 后，再用于后续的文件检索或业务接口。

## 适合的场景

- 查看某类输入文件是否已经成功上传。
- 在语音复刻或长文本语音生成前，确认待用文件列表。
- 结合文件检索接口做文件管理和任务编排。

## 使用建议

- 先明确 `purpose`，否则很容易在不同文件分类之间混淆。
- 如果你要做完整的文件管理流程，建议同时保留文件上传和文件检索的调用记录。
- 文档页面没有展开分页参数；如果官方后续补充分页能力，建议再同步更新本地整理页。

## 说明

这份整理页用于本地快速查阅。若需要最新的请求参数、返回字段和错误码，请以官方页面为准。
