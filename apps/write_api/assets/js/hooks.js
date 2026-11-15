// LiveView hooks for the dashboard, keyed by the name used in `phx-hook`.

const GOOGLE_SCRIPT = "https://accounts.google.com/gsi/client"
const SCRIPT_TIMEOUT_MS = 10000

// Loads Google's script once; resolves when `google.accounts.id` is usable, rejects when the
// script errors or does not load within the timeout.
function loadGoogleScript() {
  return new Promise((resolve, reject) => {
    if (window.google?.accounts?.id) return resolve()

    const timer = setTimeout(() => reject(new Error("timeout")), SCRIPT_TIMEOUT_MS)
    const script = document.createElement("script")
    script.src = GOOGLE_SCRIPT
    script.async = true
    script.onload = () => { clearTimeout(timer); resolve() }
    script.onerror = () => { clearTimeout(timer); reject(new Error("blocked")) }
    document.head.appendChild(script)
  })
}

// Posts the Google credential to the sign-in endpoint and returns a failure code, or null on
// success. The credential is only forwarded: it is never stored, logged or kept after the call.
async function signIn(credential) {
  let response
  try {
    response = await fetch("/auth/google", {
      method: "POST",
      credentials: "same-origin",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({credential}),
    })
  } catch (_error) {
    return "unavailable"
  }

  if (response.ok) return null

  const body = await response.json().catch(() => ({}))
  return typeof body.error === "string" ? body.error : "unknown"
}

const GoogleSignIn = {
  mounted() {
    const clientId = this.el.dataset.clientId

    loadGoogleScript()
      .then(() => {
        window.google.accounts.id.initialize({
          client_id: clientId,
          callback: async ({credential}) => {
            const code = await signIn(credential)
            if (code === null) window.location.reload()
            else this.pushEvent("sign_in_failed", {code})
          },
        })
        window.google.accounts.id.renderButton(this.el, {theme: "outline", size: "large"})
      })
      .catch(() => this.pushEvent("sign_in_failed", {code: "script_blocked"}))
  },
}

const SignOut = {
  mounted() {
    this.el.addEventListener("click", async () => {
      this.el.disabled = true
      try {
        const response = await fetch("/auth/logout", {method: "POST", credentials: "same-origin"})
        if (response.ok) return window.location.reload()
      } catch (_error) {
        // Still signed in: fall through and let the user try again.
      }
      this.el.disabled = false
    })
  },
}

// Copies `data-copy` to the clipboard. Where the async clipboard API is unavailable (a plain
// http address is not a secure context) it selects the text of the element named by
// `data-copy-target`, or of a temporary field, and tries the legacy copy command. It never
// throws and reports nothing but the button label.
async function copyText(el) {
  const text = el.dataset.copy
  if (typeof text !== "string" || text === "") return false

  try {
    if (navigator.clipboard && typeof navigator.clipboard.writeText === "function") {
      await navigator.clipboard.writeText(text)
      return true
    }
  } catch (_error) {
    // Denied or failed: fall through to selecting the text.
  }

  return selectText(el, text)
}

function selectText(el, text) {
  let temporary = null
  try {
    let field = el.dataset.copyTarget && document.getElementById(el.dataset.copyTarget)
    if (!field) {
      field = temporary = document.createElement("textarea")
      field.value = text
      field.setAttribute("readonly", "")
      field.style.position = "fixed"
      field.style.opacity = "0"
      document.body.appendChild(field)
    }
    field.focus()
    field.select()
    return document.execCommand("copy") === true
  } catch (_error) {
    return false
  } finally {
    if (temporary) temporary.remove()
  }
}

const Copy = {
  mounted() {
    this.label = this.el.textContent
    this.el.addEventListener("click", async () => {
      if (await copyText(this.el)) {
        this.el.textContent = "Copiado"
        clearTimeout(this.timer)
        this.timer = setTimeout(() => { this.el.textContent = this.label }, 1500)
      }
    })
  },
  destroyed() {
    clearTimeout(this.timer)
  },
}

export const Hooks = {GoogleSignIn, SignOut, Copy}
