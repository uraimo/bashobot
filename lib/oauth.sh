#!/bin/bash
#
# OAuth helpers for subscription providers
#

AUTH_FILE="${CONFIG_DIR:-$HOME/.bashobot}/auth.json"

# ----------------------------------------------------------------------------
# JSON helpers
# ----------------------------------------------------------------------------

oauth_init_auth_file() {
    if [[ ! -f "$AUTH_FILE" ]]; then
        mkdir -p "$(dirname "$AUTH_FILE")"
        echo "{}" > "$AUTH_FILE"
    fi
}

oauth_load_auth() {
    oauth_init_auth_file
    cat "$AUTH_FILE"
}

oauth_write_auth() {
    local payload="$1"
    echo "$payload" > "$AUTH_FILE"
}

oauth_get_credentials() {
    local provider="$1"
    oauth_load_auth | jq -c --arg provider "$provider" '.[$provider] // empty'
}

oauth_set_credentials() {
    local provider="$1"
    local creds_json="$2"

    local auth
    auth=$(oauth_load_auth)
    auth=$(echo "$auth" | jq --arg provider "$provider" --argjson creds "$creds_json" '.[$provider] = $creds')
    oauth_write_auth "$auth"
}

oauth_delete_credentials() {
    local provider="$1"
    local auth
    auth=$(oauth_load_auth)
    auth=$(echo "$auth" | jq --arg provider "$provider" 'del(.[$provider])')
    oauth_write_auth "$auth"
}

# ----------------------------------------------------------------------------
# Utility helpers
# ----------------------------------------------------------------------------

oauth_base64url_encode() {
    local input="$1"
    printf '%s' "$input" | openssl base64 -A | tr '+/' '-_' | tr -d '='
}

oauth_base64url_decode() {
    local input="$1"
    local padded="$input"
    local mod=$(( ${#padded} % 4 ))
    if [[ $mod -eq 2 ]]; then padded="${padded}=="; elif [[ $mod -eq 3 ]]; then padded="${padded}="; fi
    padded=$(echo "$padded" | tr '-_' '+/')
    printf '%s' "$padded" | base64 -d 2>/dev/null || printf '%s' "$padded" | base64 -D 2>/dev/null
}

oauth_basho_decode() {
    local input="$1"
    local decoded
    decoded=$(printf '%s' "$input" | base64 -d 2>/dev/null || printf '%s' "$input" | base64 -D 2>/dev/null)
    echo "${decoded:6}"
}

oauth_generate_pkce() {
    local verifier
    verifier=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')
    local challenge
    challenge=$(printf '%s' "$verifier" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
    echo "$verifier|$challenge"
}

oauth_url_decode() {
    local url_encoded="$1"
    printf '%b' "${url_encoded//%/\\x}"
}

oauth_parse_query_param() {
    local input="$1"
    local param="$2"
    local value
    value=$(echo "$input" | sed -n "s/.*[?&]${param}=\([^&#]*\).*/\1/p" | head -n1)
    if [[ -n "$value" ]]; then
        oauth_url_decode "$value"
        return 0
    fi
    return 1
}

# ----------------------------------------------------------------------------
# Provider-specific OAuth flows
# ----------------------------------------------------------------------------

oauth_show_auth_url() {
    local url="$1"
    local instructions="$2"
    {
        echo "Open this URL in your browser and complete login:"
        echo "$url"
        if [[ -n "$instructions" ]]; then
            echo "$instructions"
        fi
        echo ""
    } >&2
}

# Anthropic (Claude Pro/Max)
_ANTHROPIC_CLIENT_ID=$(oauth_basho_decode "YmFzaG98OWQxYzI1MGEtZTYxYi00NGQ5LTg4ZWQtNTk0ZDE5NjJmNWU=")
_ANTHROPIC_AUTHORIZE_URL="https://claude.ai/oauth/authorize"
_ANTHROPIC_TOKEN_URL="https://console.anthropic.com/v1/oauth/token"
_ANTHROPIC_REDIRECT_URI="https://console.anthropic.com/oauth/code/callback"
_ANTHROPIC_SCOPES="org:create_api_key user:profile user:inference"

oauth_login_claude_sub() {
    local pkce verifier challenge
    pkce=$(oauth_generate_pkce)
    verifier="${pkce%%|*}"
    challenge="${pkce##*|}"

    local auth_url
    auth_url="${_ANTHROPIC_AUTHORIZE_URL}?code=true&client_id=${_ANTHROPIC_CLIENT_ID}&response_type=code&redirect_uri=${_ANTHROPIC_REDIRECT_URI}&scope=${_ANTHROPIC_SCOPES}&code_challenge=${challenge}&code_challenge_method=S256&state=${verifier}"

    oauth_show_auth_url "$auth_url" ""
    read -r -p "Paste the authorization code (format: code#state): " auth_input

    local code state
    code="${auth_input%%#*}"
    state="${auth_input##*#}"

    if [[ -z "$code" || -z "$state" ]]; then
        echo "Error: Invalid authorization code format." >&2
        return 1
    fi

    local response
    response=$(curl -s -X POST "$_ANTHROPIC_TOKEN_URL" \
        -H "Content-Type: application/json" \
        -d "{\"grant_type\":\"authorization_code\",\"client_id\":\"$_ANTHROPIC_CLIENT_ID\",\"code\":\"$code\",\"state\":\"$state\",\"redirect_uri\":\"$_ANTHROPIC_REDIRECT_URI\",\"code_verifier\":\"$verifier\"}")

    local access refresh expires_in
    access=$(echo "$response" | jq -r '.access_token // empty')
    refresh=$(echo "$response" | jq -r '.refresh_token // empty')
    expires_in=$(echo "$response" | jq -r '.expires_in // 0')

    if [[ -z "$access" || -z "$refresh" || "$expires_in" == "0" ]]; then
        local err
        err=$(echo "$response" | jq -r '.error // .message // empty')
        echo "Anthropic login failed${err:+: $err}" >&2
        return 1
    fi

    local expires
    expires=$(( $(date +%s) * 1000 + expires_in * 1000 - 300000 ))

    jq -n --arg access "$access" --arg refresh "$refresh" --argjson expires "$expires" '{access:$access,refresh:$refresh,expires:$expires}'
}

oauth_refresh_claude_sub() {
    local refresh_token="$1"

    local response
    response=$(curl -s -X POST "$_ANTHROPIC_TOKEN_URL" \
        -H "Content-Type: application/json" \
        -d "{\"grant_type\":\"refresh_token\",\"client_id\":\"$_ANTHROPIC_CLIENT_ID\",\"refresh_token\":\"$refresh_token\"}")

    local access refresh expires_in
    access=$(echo "$response" | jq -r '.access_token // empty')
    refresh=$(echo "$response" | jq -r '.refresh_token // empty')
    expires_in=$(echo "$response" | jq -r '.expires_in // 0')

    if [[ -z "$access" || -z "$refresh" || "$expires_in" == "0" ]]; then
        local err
        err=$(echo "$response" | jq -r '.error // .message // empty')
        echo "Anthropic token refresh failed${err:+: $err}" >&2
        return 1
    fi

    local expires
    expires=$(( $(date +%s) * 1000 + expires_in * 1000 - 300000 ))

    jq -n --arg access "$access" --arg refresh "$refresh" --argjson expires "$expires" '{access:$access,refresh:$refresh,expires:$expires}'
}

# OpenAI Codex (ChatGPT OAuth)
_OPENAI_CODEX_CLIENT_ID=$(oauth_basho_decode "YmFzaG98YXBwX0VNb2FtRUVaNzNmMENrWGFYcDdocmFubg==")
_OPENAI_CODEX_AUTHORIZE_URL="https://auth.openai.com/oauth/authorize"
_OPENAI_CODEX_TOKEN_URL="https://auth.openai.com/oauth/token"
_OPENAI_CODEX_REDIRECT_URI="http://localhost:1455/auth/callback"
_OPENAI_CODEX_SCOPE="openid profile email offline_access"

_openai_codex_parse_auth_input() {
    local input="$1"
    local code
    local state

    if [[ "$input" == *"#"* ]]; then
        code="${input%%#*}"
        state="${input##*#}"
    else
        code=$(oauth_parse_query_param "$input" "code" || true)
        state=$(oauth_parse_query_param "$input" "state" || true)
        if [[ -z "$code" ]]; then
            code="$input"
        fi
    fi

    echo "$code|$state"
}

oauth_login_openai_sub() {
    local pkce verifier challenge
    pkce=$(oauth_generate_pkce)
    verifier="${pkce%%|*}"
    challenge="${pkce##*|}"

    local state
    state=$(openssl rand -hex 16)

    local auth_url
    auth_url="${_OPENAI_CODEX_AUTHORIZE_URL}?response_type=code&client_id=${_OPENAI_CODEX_CLIENT_ID}&redirect_uri=${_OPENAI_CODEX_REDIRECT_URI}&scope=${_OPENAI_CODEX_SCOPE}&code_challenge=${challenge}&code_challenge_method=S256&state=${state}&id_token_add_organizations=true&codex_cli_simplified_flow=true&originator=pi"

    oauth_show_auth_url "$auth_url" ""
    read -r -p "Paste the authorization code or redirect URL: " auth_input

    local parsed code returned_state
    parsed=$(_openai_codex_parse_auth_input "$auth_input")
    code="${parsed%%|*}"
    returned_state="${parsed##*|}"

    if [[ -n "$returned_state" && "$returned_state" != "$state" ]]; then
        echo "Error: OAuth state mismatch." >&2
        return 1
    fi

    if [[ -z "$code" ]]; then
        echo "Error: Missing authorization code." >&2
        return 1
    fi

    local response
    response=$(curl -s -X POST "$_OPENAI_CODEX_TOKEN_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=authorization_code&client_id=${_OPENAI_CODEX_CLIENT_ID}&code=${code}&code_verifier=${verifier}&redirect_uri=${_OPENAI_CODEX_REDIRECT_URI}")

    local access refresh expires_in
    access=$(echo "$response" | jq -r '.access_token // empty')
    refresh=$(echo "$response" | jq -r '.refresh_token // empty')
    expires_in=$(echo "$response" | jq -r '.expires_in // 0')

    if [[ -z "$access" || -z "$refresh" || "$expires_in" == "0" ]]; then
        local err
        err=$(echo "$response" | jq -r '.error_description // .error // empty')
        echo "OpenAI login failed${err:+: $err}" >&2
        return 1
    fi

    local expires account_id
    expires=$(( $(date +%s) * 1000 + expires_in * 1000 ))
    account_id=$(oauth_extract_openai_account_id "$access")

    if [[ -z "$account_id" ]]; then
        echo "Error: Failed to extract OpenAI account id from token." >&2
        return 1
    fi

    jq -n --arg access "$access" --arg refresh "$refresh" --argjson expires "$expires" --arg account_id "$account_id" '{access:$access,refresh:$refresh,expires:$expires,accountId:$account_id}'
}

oauth_refresh_openai_sub() {
    local refresh_token="$1"

    local response
    response=$(curl -s -X POST "$_OPENAI_CODEX_TOKEN_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=refresh_token&refresh_token=${refresh_token}&client_id=${_OPENAI_CODEX_CLIENT_ID}")

    local access refresh expires_in
    access=$(echo "$response" | jq -r '.access_token // empty')
    refresh=$(echo "$response" | jq -r '.refresh_token // empty')
    expires_in=$(echo "$response" | jq -r '.expires_in // 0')

    if [[ -z "$access" || -z "$refresh" || "$expires_in" == "0" ]]; then
        local err
        err=$(echo "$response" | jq -r '.error_description // .error // empty')
        echo "OpenAI token refresh failed${err:+: $err}" >&2
        return 1
    fi

    local expires account_id
    expires=$(( $(date +%s) * 1000 + expires_in * 1000 ))
    account_id=$(oauth_extract_openai_account_id "$access")

    if [[ -z "$account_id" ]]; then
        echo "Error: Failed to extract OpenAI account id from token." >&2
        return 1
    fi

    jq -n --arg access "$access" --arg refresh "$refresh" --argjson expires "$expires" --arg account_id "$account_id" '{access:$access,refresh:$refresh,expires:$expires,accountId:$account_id}'
}

oauth_extract_openai_account_id() {
    local token="$1"
    local payload
    payload=$(echo "$token" | awk -F'.' '{print $2}')
    if [[ -z "$payload" ]]; then
        return 1
    fi
    local decoded
    decoded=$(oauth_base64url_decode "$payload")
    echo "$decoded" | jq -r '."https://api.openai.com/auth".chatgpt_account_id // empty'
}

# Google Gemini CLI (Cloud Code Assist)
_GEMINI_CLIENT_ID=$(oauth_basho_decode "YmFzaG98NjgxMjU1ODA5Mzk1LW9vOGZ0Mm9wcmRybnA5ZTNhcWY2YXYzaG1kaWIxMzVqLmFwcHMuZ29vZ2xldXNlcmNvbnRlbnQuY29t")
_GEMINI_CLIENT_SECRET=$(oauth_basho_decode "YmFzaG98R09DU1BYLTR1SGdNUG0tMW83U2stZ2VWNkN1NWNsWEZzeGw=")
_GEMINI_REDIRECT_URI="http://localhost:8085/oauth2callback"
_GEMINI_AUTH_URL="https://accounts.google.com/o/oauth2/v2/auth"
_GEMINI_TOKEN_URL="https://oauth2.googleapis.com/token"
_GEMINI_SCOPES="https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile"

_google_parse_redirect_code() {
    local input="$1"
    local code state
    code=$(oauth_parse_query_param "$input" "code" || true)
    state=$(oauth_parse_query_param "$input" "state" || true)
    if [[ -z "$code" && "$input" != *"?"* ]]; then
        code="$input"
    fi
    echo "$code|$state"
}

oauth_login_gemini_sub() {
    local pkce verifier challenge
    pkce=$(oauth_generate_pkce)
    verifier="${pkce%%|*}"
    challenge="${pkce##*|}"

    local auth_url
    auth_url="${_GEMINI_AUTH_URL}?client_id=${_GEMINI_CLIENT_ID}&response_type=code&redirect_uri=${_GEMINI_REDIRECT_URI}&scope=$(printf '%s' "$_GEMINI_SCOPES" | sed 's/ /%20/g')&code_challenge=${challenge}&code_challenge_method=S256&state=${verifier}&access_type=offline&prompt=consent"

    oauth_show_auth_url "$auth_url" ""
    read -r -p "Paste the redirect URL or authorization code: " auth_input

    local parsed code state
    parsed=$(_google_parse_redirect_code "$auth_input")
    code="${parsed%%|*}"
    state="${parsed##*|}"

    if [[ -n "$state" && "$state" != "$verifier" ]]; then
        echo "Error: OAuth state mismatch." >&2
        return 1
    fi

    if [[ -z "$code" ]]; then
        echo "Error: Missing authorization code." >&2
        return 1
    fi

    local response
    response=$(curl -s -X POST "$_GEMINI_TOKEN_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "client_id=${_GEMINI_CLIENT_ID}&client_secret=${_GEMINI_CLIENT_SECRET}&code=${code}&grant_type=authorization_code&redirect_uri=${_GEMINI_REDIRECT_URI}&code_verifier=${verifier}")

    local access refresh expires_in
    access=$(echo "$response" | jq -r '.access_token // empty')
    refresh=$(echo "$response" | jq -r '.refresh_token // empty')
    expires_in=$(echo "$response" | jq -r '.expires_in // 0')

    if [[ -z "$access" || -z "$refresh" || "$expires_in" == "0" ]]; then
        local err
        err=$(echo "$response" | jq -r '.error // .error_description // empty')
        echo "Gemini CLI login failed${err:+: $err}" >&2
        return 1
    fi

    local project_id
    project_id=$(oauth_discover_google_project "$access")
    if [[ -z "$project_id" ]]; then
        read -r -p "Enter Google Cloud project ID for Code Assist: " project_id
    fi

    if [[ -z "$project_id" ]]; then
        echo "Error: Missing project ID." >&2
        return 1
    fi

    local expires
    expires=$(( $(date +%s) * 1000 + expires_in * 1000 - 300000 ))

    jq -n --arg access "$access" --arg refresh "$refresh" --argjson expires "$expires" --arg projectId "$project_id" '{access:$access,refresh:$refresh,expires:$expires,projectId:$projectId}'
}

oauth_refresh_gemini_sub() {
    local refresh_token="$1"
    local project_id="$2"

    local response
    response=$(curl -s -X POST "$_GEMINI_TOKEN_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "client_id=${_GEMINI_CLIENT_ID}&client_secret=${_GEMINI_CLIENT_SECRET}&refresh_token=${refresh_token}&grant_type=refresh_token")

    local access expires_in
    access=$(echo "$response" | jq -r '.access_token // empty')
    expires_in=$(echo "$response" | jq -r '.expires_in // 0')
    local new_refresh
    new_refresh=$(echo "$response" | jq -r '.refresh_token // empty')

    if [[ -z "$access" || "$expires_in" == "0" ]]; then
        local err
        err=$(echo "$response" | jq -r '.error // .error_description // empty')
        echo "Gemini token refresh failed${err:+: $err}" >&2
        return 1
    fi

    local expires
    expires=$(( $(date +%s) * 1000 + expires_in * 1000 - 300000 ))
    local refresh="$refresh_token"
    if [[ -n "$new_refresh" ]]; then
        refresh="$new_refresh"
    fi

    jq -n --arg access "$access" --arg refresh "$refresh" --argjson expires "$expires" --arg projectId "$project_id" '{access:$access,refresh:$refresh,expires:$expires,projectId:$projectId}'
}

# Google Antigravity
_ANTIGRAVITY_CLIENT_ID=$(oauth_basho_decode "YmFzaG98MTA3MTAwNjA2MDU5MS10bWhzc2luMmgyMWxjcmUyMzV2dG9sb2poNGc0MDNlcC5hcHBzLmdvb2dsZXVzZXJjb250ZW50LmNvbQ==")
_ANTIGRAVITY_CLIENT_SECRET=$(oauth_basho_decode "YmFzaG98R09DU1BYLUs1OEZXUjQ4NkxkTEoxbUxCOHNYQzR6NnFEQWY=")
_ANTIGRAVITY_REDIRECT_URI="http://localhost:51121/oauth-callback"
_ANTIGRAVITY_AUTH_URL="https://accounts.google.com/o/oauth2/v2/auth"
_ANTIGRAVITY_TOKEN_URL="https://oauth2.googleapis.com/token"
_ANTIGRAVITY_SCOPES="https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/cclog https://www.googleapis.com/auth/experimentsandconfigs"
_ANTIGRAVITY_DEFAULT_PROJECT_ID="rising-fact-p41fc"

oauth_login_antigravity_sub() {
    local pkce verifier challenge
    pkce=$(oauth_generate_pkce)
    verifier="${pkce%%|*}"
    challenge="${pkce##*|}"

    local auth_url
    auth_url="${_ANTIGRAVITY_AUTH_URL}?client_id=${_ANTIGRAVITY_CLIENT_ID}&response_type=code&redirect_uri=${_ANTIGRAVITY_REDIRECT_URI}&scope=$(printf '%s' "$_ANTIGRAVITY_SCOPES" | sed 's/ /%20/g')&code_challenge=${challenge}&code_challenge_method=S256&state=${verifier}&access_type=offline&prompt=consent"

    oauth_show_auth_url "$auth_url" ""
    read -r -p "Paste the redirect URL or authorization code: " auth_input

    local parsed code state
    parsed=$(_google_parse_redirect_code "$auth_input")
    code="${parsed%%|*}"
    state="${parsed##*|}"

    if [[ -n "$state" && "$state" != "$verifier" ]]; then
        echo "Error: OAuth state mismatch." >&2
        return 1
    fi

    if [[ -z "$code" ]]; then
        echo "Error: Missing authorization code." >&2
        return 1
    fi

    local response
    response=$(curl -s -X POST "$_ANTIGRAVITY_TOKEN_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "client_id=${_ANTIGRAVITY_CLIENT_ID}&client_secret=${_ANTIGRAVITY_CLIENT_SECRET}&code=${code}&grant_type=authorization_code&redirect_uri=${_ANTIGRAVITY_REDIRECT_URI}&code_verifier=${verifier}")

    local access refresh expires_in
    access=$(echo "$response" | jq -r '.access_token // empty')
    refresh=$(echo "$response" | jq -r '.refresh_token // empty')
    expires_in=$(echo "$response" | jq -r '.expires_in // 0')

    if [[ -z "$access" || -z "$refresh" || "$expires_in" == "0" ]]; then
        local err
        err=$(echo "$response" | jq -r '.error // .error_description // empty')
        echo "Antigravity login failed${err:+: $err}" >&2
        return 1
    fi

    local project_id
    project_id=$(oauth_discover_google_project "$access")
    if [[ -z "$project_id" ]]; then
        project_id="$_ANTIGRAVITY_DEFAULT_PROJECT_ID"
    fi

    local expires
    expires=$(( $(date +%s) * 1000 + expires_in * 1000 - 300000 ))

    jq -n --arg access "$access" --arg refresh "$refresh" --argjson expires "$expires" --arg projectId "$project_id" '{access:$access,refresh:$refresh,expires:$expires,projectId:$projectId}'
}

oauth_refresh_antigravity_sub() {
    local refresh_token="$1"
    local project_id="$2"

    local response
    response=$(curl -s -X POST "$_ANTIGRAVITY_TOKEN_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "client_id=${_ANTIGRAVITY_CLIENT_ID}&client_secret=${_ANTIGRAVITY_CLIENT_SECRET}&refresh_token=${refresh_token}&grant_type=refresh_token")

    local access expires_in
    access=$(echo "$response" | jq -r '.access_token // empty')
    expires_in=$(echo "$response" | jq -r '.expires_in // 0')
    local new_refresh
    new_refresh=$(echo "$response" | jq -r '.refresh_token // empty')

    if [[ -z "$access" || "$expires_in" == "0" ]]; then
        local err
        err=$(echo "$response" | jq -r '.error // .error_description // empty')
        echo "Antigravity token refresh failed${err:+: $err}" >&2
        return 1
    fi

    local expires
    expires=$(( $(date +%s) * 1000 + expires_in * 1000 - 300000 ))
    local refresh="$refresh_token"
    if [[ -n "$new_refresh" ]]; then
        refresh="$new_refresh"
    fi

    jq -n --arg access "$access" --arg refresh "$refresh" --argjson expires "$expires" --arg projectId "$project_id" '{access:$access,refresh:$refresh,expires:$expires,projectId:$projectId}'
}

# Discover a Google Cloud project for Code Assist, best-effort
# Returns project ID or empty string

oauth_discover_google_project() {
    local access_token="$1"
    local env_project
    env_project="${GOOGLE_CLOUD_PROJECT:-${GOOGLE_CLOUD_PROJECT_ID:-}}"
    if [[ -n "$env_project" ]]; then
        echo "$env_project"
        return 0
    fi

    local response
    response=$(curl -s -X POST "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist" \
        -H "Authorization: Bearer ${access_token}" \
        -H "Content-Type: application/json" \
        -H "User-Agent: google-cloud-sdk vscode_cloudshelleditor/0.1" \
        -H "X-Goog-Api-Client: gl-node/22.17.0" \
        -H "Client-Metadata: {\"ideType\":\"IDE_UNSPECIFIED\",\"platform\":\"PLATFORM_UNSPECIFIED\",\"pluginType\":\"GEMINI\"}" \
        -d '{"metadata":{"ideType":"IDE_UNSPECIFIED","platform":"PLATFORM_UNSPECIFIED","pluginType":"GEMINI"}}')

    local project_id
    project_id=$(echo "$response" | jq -r '.cloudaicompanionProject // empty')
    if [[ "$project_id" == "null" ]]; then
        project_id=""
    fi
    if [[ -z "$project_id" ]]; then
        project_id=$(echo "$response" | jq -r '.cloudaicompanionProject.id // empty')
    fi

    echo "$project_id"
}

# ----------------------------------------------------------------------------
# Public API
# ----------------------------------------------------------------------------

oauth_login_provider() {
    local provider="$1"
    local creds

    echo "Before proceeding, verify that using your subscription with other applications is allowed by your provider's Terms of Service."
    read -r -p "Type Yes to continue: " confirm
    if [[ "$confirm" != "Yes" ]]; then
        echo "Login cancelled."
        return 1
    fi

    case "$provider" in
        claude-sub)
            creds=$(oauth_login_claude_sub) || return 1
            ;;
        openai-sub)
            creds=$(oauth_login_openai_sub) || return 1
            ;;
        gemini-sub)
            creds=$(oauth_login_gemini_sub) || return 1
            ;;
        antigravity-sub)
            creds=$(oauth_login_antigravity_sub) || return 1
            ;;
        *)
            echo "Unknown OAuth provider: $provider" >&2
            return 1
            ;;
    esac

        oauth_set_credentials "$provider" "$creds"
    echo "Saved credentials to $AUTH_FILE"
}

oauth_logout_provider() {
    local provider="$1"

    if [[ -z "$provider" ]]; then
        echo "Error: Provider required" >&2
        return 1
    fi

    oauth_delete_credentials "$provider"
    echo "Removed credentials for $provider from $AUTH_FILE"
}

oauth_get_access_token() {
    local provider="$1"
    local creds
    creds=$(oauth_get_credentials "$provider")

    if [[ -z "$creds" ]]; then
        return 1
    fi

    local expires
    expires=$(echo "$creds" | jq -r '.expires // 0')
    local now
    now=$(( $(date +%s) * 1000 ))

    if [[ "$expires" != "0" && "$now" -ge "$expires" ]]; then
        local refreshed
        case "$provider" in
            claude-sub)
                refreshed=$(oauth_refresh_claude_sub "$(echo "$creds" | jq -r '.refresh')") || return 1
                ;;
            openai-sub)
                refreshed=$(oauth_refresh_openai_sub "$(echo "$creds" | jq -r '.refresh')") || return 1
                ;;
            gemini-sub)
                refreshed=$(oauth_refresh_gemini_sub "$(echo "$creds" | jq -r '.refresh')" "$(echo "$creds" | jq -r '.projectId')") || return 1
                ;;
            antigravity-sub)
                refreshed=$(oauth_refresh_antigravity_sub "$(echo "$creds" | jq -r '.refresh')" "$(echo "$creds" | jq -r '.projectId')") || return 1
                ;;
            *)
                return 1
                ;;
        esac
        oauth_set_credentials "$provider" "$refreshed"
        creds="$refreshed"
    fi

    echo "$creds"
}
