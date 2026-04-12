# Critical Finding 08: SSL Certificate Verification Disabled in rocinsight LLM Client

| Field              | Value                                         |
|--------------------|-----------------------------------------------|
| **Finding ID**     | CRIT-08                                       |
| **Category**       | Transport Security / Certificate Validation   |
| **Affected Files** | `experimental/python/rocinsight/rocinsight/ai_analysis/llm_analyzer.py` (line 1088), `experimental/python/rocinsight/rocinsight/ai_analysis/llm_conversation.py` (line 91) |
| **Tool**           | Manual review, Bandit B501                    |
| **Date**           | 2026-04-11                                    |

---

## 1. Summary

Two files in the rocinsight experimental LLM integration contain `verify=False` calls
that disable SSL/TLS certificate verification when communicating with a private LLM
endpoint. A third file initially flagged (`projects/amdsmi/tests/abi_check/abi_check.py`)
contains **no** SSL or HTTP operations whatsoever -- it is a local ABI compliance checker
using `git show` and `subprocess`. That file is a false positive and is excluded from
this analysis.

---

## 2. Affected Locations

### 2.1 `llm_analyzer.py` -- `_call_private()` method (line 1088)

**File:** `experimental/python/rocinsight/rocinsight/ai_analysis/llm_analyzer.py`

```python
# Lines 1022-1103
def _call_private(self, system_prompt: str, user_prompt: str) -> str:
    """Call a private/enterprise OpenAI-compatible LLM server.

    Configuration via environment variables:
        ROCINSIGHT_LLM_PRIVATE_URL        Base URL (required)
        ROCINSIGHT_LLM_PRIVATE_MODEL      Model name (required)
        ROCINSIGHT_LLM_PRIVATE_API_KEY    API key (default: "dummy")
        ROCINSIGHT_LLM_PRIVATE_HEADERS    JSON object of extra request headers
                                     (the "user" header defaults to os.getlogin())
        ROCINSIGHT_LLM_PRIVATE_VERIFY_SSL Set to "0" or "false" to disable SSL
                                     certificate verification (requires httpx).
    """
    # ... URL/model/key/header setup ...

    verify_ssl_env = os.environ.get("ROCINSIGHT_LLM_PRIVATE_VERIFY_SSL", "1").lower()
    verify_ssl = verify_ssl_env not in ("0", "false", "no")
    http_client = None
    if not verify_ssl:
        try:
            import httpx as _httpx

            http_client = _httpx.Client(verify=False)       # <--- FINDING
        except ImportError:
            import warnings
            warnings.warn(
                "ROCINSIGHT_LLM_PRIVATE_VERIFY_SSL=0 requested but httpx is not installed. "
                "SSL verification will remain enabled. Run: pip install httpx",
                stacklevel=2,
            )

    client_kwargs: dict = dict(
        api_key=key, base_url=base_url, default_headers=headers
    )
    if http_client is not None:
        client_kwargs["http_client"] = http_client
    client = openai.OpenAI(**client_kwargs)

    resp = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        max_completion_tokens=4096,
    )
```

**Data sent over the connection:** System prompts and user prompts containing GPU
profiling data, performance metrics, and diagnostic information from AMD GPU workloads.
API keys and custom headers (potentially including subscription keys) are also
transmitted.

**Endpoint:** Determined entirely by `ROCINSIGHT_LLM_PRIVATE_URL`. The docstring
example is `https://my-apim.example.com/openai/deployments/gpt4` -- an enterprise
Azure API Management gateway.

**Config control:** `ROCINSIGHT_LLM_PRIVATE_VERIFY_SSL` environment variable.
**Default is `"1"` (SSL verification ENABLED).** Must be explicitly set to `"0"`,
`"false"`, or `"no"` to disable.


### 2.2 `llm_conversation.py` -- `_build_private_client()` function (line 91)

**File:** `experimental/python/rocinsight/rocinsight/ai_analysis/llm_conversation.py`

```python
# Lines 20-105
def _build_private_client(api_key: Optional[str], model_override: Optional[str]):
    """Build an OpenAI client for a private/enterprise LLM server.

    Reads configuration from environment variables:
        ROCINSIGHT_LLM_PRIVATE_URL        Base URL of the private server (required)
        ROCINSIGHT_LLM_PRIVATE_MODEL      Model name to use
        ROCINSIGHT_LLM_PRIVATE_API_KEY    API key (default: "dummy" for header-auth servers)
        ROCINSIGHT_LLM_PRIVATE_HEADERS    JSON object of extra request headers
        ROCINSIGHT_LLM_PRIVATE_VERIFY_SSL Set to "0" or "false" to disable SSL certificate
                                     verification (e.g. for corporate proxies with
                                     self-signed certs). Requires httpx package.
    """
    # ... same pattern ...

    verify_ssl_env = os.environ.get("ROCINSIGHT_LLM_PRIVATE_VERIFY_SSL", "1").lower()
    verify_ssl = verify_ssl_env not in ("0", "false", "no")
    http_client = None
    if not verify_ssl:
        try:
            import httpx as _httpx

            http_client = _httpx.Client(verify=False)       # <--- FINDING
        except ImportError:
            warnings.warn(
                "[LLMConversation] ROCINSIGHT_LLM_PRIVATE_VERIFY_SSL=0 requested but httpx is "
                "not installed. SSL verification will remain enabled. "
                "Run: pip install httpx",
                stacklevel=3,
            )

    kwargs: Dict[str, Any] = dict(api_key=key, base_url=base_url, default_headers=headers)
    if http_client is not None:
        kwargs["http_client"] = http_client
    client = _openai.OpenAI(**kwargs)
    return client, model, http_client
```

**Data sent:** Same as 2.1 -- LLM prompts containing GPU diagnostic data, plus
multi-turn conversation history (the `LLMConversation` class manages persistent
sessions with compaction).

**Endpoint:** Same `ROCINSIGHT_LLM_PRIVATE_URL` environment variable. The file also
defines `_DEFAULT_LOCAL_URL = "http://localhost:11434/v1"` (Ollama local inference),
but the `_build_private_client` function requires `ROCINSIGHT_LLM_PRIVATE_URL` to
be explicitly set and does not fall back to localhost.

**Config control:** Identical to 2.1 -- `ROCINSIGHT_LLM_PRIVATE_VERIFY_SSL`, default
is enabled.


### 2.3 `amdsmi/tests/abi_check/abi_check.py` -- FALSE POSITIVE

**File:** `projects/amdsmi/tests/abi_check/abi_check.py`

This file was flagged in the initial triage but contains **zero** HTTP, SSL, or
network operations. It is a local ABI compliance checker that:
- Copies header files with `cp`
- Runs `git show` to fetch old header versions
- Invokes `abi-compliance-checker` via `subprocess`

There is no `verify=False`, no `requests`, no `urllib`, no `httpx` in this file.
**This is not a finding.**

---

## 3. Test Coverage

The `verify=False` behavior is explicitly tested in
`experimental/python/rocinsight/rocinsight/ai_analysis/tests/test_llm_private.py`:

- `test_verify_ssl_false_uses_httpx_client` (line 115): Sets
  `ROCINSIGHT_LLM_PRIVATE_VERIFY_SSL=0`, asserts `httpx.Client(verify=False)` is called.
- `test_ssl_disabled_false_value` (line 445): Same test with the string `"false"` instead
  of `"0"`.
- Multiple tests confirm that when the env var is absent, SSL verification remains
  enabled (the default path does not create an httpx client at all).

This confirms the behavior is intentional, documented, and tested.

---

## 4. Exploitability Assessment

### 4.1 Is this experimental code?

**Yes.** Both files live under `experimental/python/rocinsight/`. The `experimental/`
directory is not part of the core ROCm build system. rocinsight is a diagnostic and
profiling analysis tool, not a shipped production component.

### 4.2 What is the typical LLM endpoint?

The code supports three provider paths:
1. **Anthropic** (public API) -- does NOT use this code path; uses the anthropic SDK
   with default SSL.
2. **OpenAI** (public API) -- does NOT use this code path; uses standard openai SDK.
3. **Private/Enterprise** -- THIS code path. Targets internal corporate LLM gateways
   (Azure APIM, vLLM, TGI) or local inference servers (Ollama at localhost:11434).

The `verify=False` path is exclusively for the "private" provider, meaning corporate
internal or localhost endpoints.

### 4.3 Is SSL verification disabled by default?

**No.** The default is `"1"` (enabled):
```python
verify_ssl_env = os.environ.get("ROCINSIGHT_LLM_PRIVATE_VERIFY_SSL", "1").lower()
verify_ssl = verify_ssl_env not in ("0", "false", "no")
```
A user must explicitly set the environment variable to disable verification.
Additionally, the `httpx` package must be installed -- without it, the disable
request is silently ignored and SSL verification remains active.

### 4.4 Realistic deployment scenario

The documented use case (in the docstring and README) is: a developer on an AMD GPU
cluster is debugging performance issues, connects rocinsight to a corporate LLM
gateway behind an API management proxy that uses a self-signed or corporate-CA
certificate. The developer sets `ROCINSIGHT_LLM_PRIVATE_VERIFY_SSL=0` to bypass
the certificate check because their corporate CA is not in the system trust store.

### 4.5 How realistic is a MITM attack?

For the intended deployment scenarios:
- **Localhost (Ollama):** Zero network exposure. MITM is not possible.
- **Corporate GPU cluster internal network:** These are typically isolated HPC
  networks with controlled physical access, managed switches, and no public internet
  routing. MITM requires physical access to the cluster fabric or compromise of a
  cluster node -- at which point the attacker already has direct access to the GPU
  data. The SSL bypass adds negligible incremental risk.
- **Public internet:** If someone pointed `ROCINSIGHT_LLM_PRIVATE_URL` at a public
  endpoint AND disabled SSL verification, a MITM could intercept GPU profiling data.
  However, this would require the user to simultaneously misconfigure two settings
  (point at a public URL + disable SSL), which is an unlikely configuration error.

---

## 5. Concrete Fixes

### Fix 1: Add a runtime warning when SSL is disabled (low effort, high value)

Currently, the `warnings.warn()` only fires when httpx is missing. When SSL is
actually successfully disabled, there is no runtime warning. Add one:

```python
# In both llm_analyzer.py and llm_conversation.py, after the httpx.Client creation:
if not verify_ssl:
    try:
        import httpx as _httpx
        http_client = _httpx.Client(verify=False)
        warnings.warn(
            "SSL certificate verification is DISABLED (ROCINSIGHT_LLM_PRIVATE_VERIFY_SSL=0). "
            "Connections to the LLM endpoint are vulnerable to interception. "
            "Only use this on trusted internal networks.",
            stacklevel=2,
        )
    except ImportError:
        # existing warning ...
```

### Fix 2: Support custom CA bundle instead of full disable (medium effort)

Add a `ROCINSIGHT_LLM_PRIVATE_CA_BUNDLE` environment variable that points to a
PEM file or directory, allowing users with corporate CAs to maintain verification:

```python
ca_bundle = os.environ.get("ROCINSIGHT_LLM_PRIVATE_CA_BUNDLE", "")
if ca_bundle:
    import httpx as _httpx
    http_client = _httpx.Client(verify=ca_bundle)
elif not verify_ssl:
    # existing disable path
```

This addresses the root cause (corporate CA not in trust store) without disabling
verification entirely.

### Fix 3: Consolidate duplicated SSL logic (code quality)

The SSL disable logic is duplicated between `llm_analyzer.py:_call_private()` and
`llm_conversation.py:_build_private_client()`. Refactor into a single shared
function (e.g., `_create_ssl_aware_httpx_client()`) in a common module to ensure
both paths stay in sync.

---

## 6. Severity Rating

| Dimension                | Assessment                                           |
|--------------------------|------------------------------------------------------|
| **CWE**                  | CWE-295: Improper Certificate Validation             |
| **CVSS Base (theoretical)** | 5.9 (Medium) -- network-based, high complexity    |
| **Default exposure**     | **None** -- SSL verification is ON by default        |
| **Requires explicit opt-in** | Yes -- env var must be set AND httpx installed  |
| **Code location**        | `experimental/` -- not a shipped production component|
| **Intended use**         | Corporate internal networks with self-signed certs   |
| **Test coverage**        | Comprehensive -- both enable and disable paths tested|
| **Practical severity**   | **Low**                                              |

### Honest Assessment

This is a **well-designed escape hatch** for a legitimate enterprise use case
(corporate CAs / self-signed certificates on internal LLM gateways). The
implementation follows security best practices:

1. SSL verification is **enabled by default**.
2. Disabling requires **explicit opt-in** via environment variable.
3. The env var name (`ROCINSIGHT_LLM_PRIVATE_VERIFY_SSL`) clearly signals its purpose.
4. It only applies to the "private" provider path -- public API providers (Anthropic,
   OpenAI) are unaffected.
5. The code lives in `experimental/` and is not part of the shipped ROCm stack.

The only legitimate improvement is adding a runtime warning when SSL is actually
disabled (Fix 1) and offering a CA bundle alternative (Fix 2). Removing the
`verify=False` capability entirely would break the documented corporate deployment
workflow.

**Real-world risk: Low.** This is not a vulnerability in practice -- it is
an intentional, opt-in, documented configuration option for internal network
deployments. The `amdsmi/tests/abi_check/abi_check.py` reference is a false
positive with no SSL operations.
