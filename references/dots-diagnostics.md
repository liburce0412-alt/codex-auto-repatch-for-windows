# Missing dots entry

Use this reference when a user reports that the newly released dots feature has no entry in Windows Desktop. Look up unfamiliar product names in current official documentation before asking the user to identify them.

Official sources: [dots](https://learn.chatgpt.com/docs/dots), [getting started](https://learn.chatgpt.com/docs/dots/getting-started). Consult these again for current rollout, plan, region and workspace requirements; do not freeze the rollout rules into a patch.

dots runs a persistent agent in the cloud. A normal local Codex thread or a custom OpenAI-compatible model provider does not supply the dots cloud service. Local computer connection is a separate capability and does not make this a phone remote-control repair.

## Read-only triage

Inspect the registered and running package before selecting an ASAR. For the current-user registered package:

```powershell
$app = Get-AppxPackage -Name OpenAI.Codex
if (@($app).Count -ne 1) { throw 'Resolve the source package before inspecting dots' }
python "$SkillRoot\scripts\diagnose-dots.py" --asar (Join-Path $app.InstallLocation 'app\resources\app.asar')
```

The script reads selected assets in place, does not extract the package, does not access credentials, and does not query or create a dot. It reports detected code only. An unsupported layout, read failure or exceeded budget must fail explicitly; a missing marker is not proof that dots is absent.

Observed in Desktop 26.1016.8120.1:

- `codex://dots` maps through `dotsHome` to `/dots`, which redirects to `/dots/home`.
- The landing page and conversation route are separate lazy-loaded assets. `FeatureNavigationRoute` can redirect back to `/` when its access conditions are false. Opening the protocol alone is not a gate bypass.
- The sidebar path includes `codex-app-side-orb-enabled`; the cloud path includes `codex-app-aeon-cloud-mode` or its no-executor variant. These are different conditions; do not infer the whole feature state from a single flag.
- Account capability reads `accounts[accountId].account.tbo_config.tbo_available === true`. Local-computer access can additionally require workspace RBAC permission `chatgpt.workspace.feature.orbit.local-computer.access`.
- The primary dot is requested with authenticated `GET /tbo/primary` and the selected ChatGPT account header. A custom model `base_url` does not replace this endpoint.

Inspect only relevant configuration keys and summarized recent Desktop logs. `model_provider = "custom"` identifies model routing, not the state of any separate ChatGPT session. Missing `auth.json` does not prove logout: credentials may use another store. `Workspace routing is unavailable` is evidence of an unavailable account/workspace request path, not proof that a particular plan or region is ineligible. Never dump auth files, cookies, account identifiers or the entire global state to obtain this diagnosis.

## Choosing the next action

If code is present but account/workspace routing is unavailable, resolve the supported ChatGPT sign-in/workspace path first while preserving the user's provider configuration. Do not replace credentials or switch the model provider without establishing that it is necessary. Check account eligibility through the normal client/account interface; do not change `tbo_available`, RBAC, or cached account responses to fabricate it.

For manual inspection, the user can run the built-in protocol:

```powershell
Start-Process 'codex://dots'
```

This can navigate or focus the running app. Give it as an optional manual diagnostic, not a verified repair or an instruction to restart Desktop. When the available GUI skill prohibits automating the host app, do not use another input mechanism to evade that boundary.

Only prepare an entry-visibility patch after evidence establishes a usable account/service and a specifically closed client presentation gate. Preserve the real login, rollout, workspace and service errors. Do not blanket-enable aeon flags or add dots to the default non-phone patch set. Route existence, visible entry, successful eligibility check and actual cloud task execution are separate acceptance results.
