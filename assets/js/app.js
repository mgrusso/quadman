import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

// Hooks
const Hooks = {}

// Smart log streaming hook:
// - Auto-scrolls to bottom when new lines arrive, unless user has scrolled up
// - Notifies LiveView when the at-bottom state changes (shows/hides the jump button)
Hooks.LogStream = {
  mounted() {
    this.atBottom = true
    this.scrollToBottom()

    this.el.addEventListener('scroll', () => {
      const el = this.el
      const wasAtBottom = this.atBottom
      this.atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 50

      if (this.atBottom !== wasAtBottom) {
        this.pushEvent('scroll_position', { at_bottom: this.atBottom })
      }
    })
  },
  updated() {
    if (this.atBottom) this.scrollToBottom()
  },
  scrollToBottom() {
    this.el.scrollTop = this.el.scrollHeight
  }
}

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: Hooks
})

topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()
window.liveSocket = liveSocket
