//
//  HeyClickySecrets.swift
//
//  Empty-by-default template. The public git tree ships this file
//  with empty strings — a fresh clone compiles but the HeyClicky
//  Free lane self-disables (all endpoints throw
//  HeyClickyConfigError).
//
//  Personal builds fill the values in and hide the change from git:
//
//      git update-index --skip-worktree \
//          cursor-buddy/HeyClickySecrets.swift
//
//  Undo before pulling / committing shared refactors:
//
//      git update-index --no-skip-worktree \
//          cursor-buddy/HeyClickySecrets.swift
//

import Foundation

enum HeyClickySecrets {
    /// Cloudflare Worker proxy that fronts /chat-tool-call, agent
    /// lease, realtime ephemeral, etc.
    static let proxyBaseURL: String = ""

    /// Supabase project the proxy is bound to; used for OAuth token
    /// refresh (POST /auth/v1/token?grant_type=refresh_token).
    static let supabaseURL: String = ""

    /// Supabase anon (row-level-security scoped) JWT sent as `apikey`
    /// on all /auth/v1/* requests.
    static let supabaseAnonKey: String = ""

    /// Full `authorize?provider=google&redirect_to=clicky://auth-callback`
    /// URL. When empty at runtime, HeyClickyOAuthHandler throws and
    /// the "Sign in with Google" button becomes a no-op.
    static let oauthAuthorizeURL: String = ""
}
