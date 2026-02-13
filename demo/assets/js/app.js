// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/demo"
import topbar from "../vendor/topbar"
import {PostgrestClient} from "@supabase/postgrest-js"
import Prism from "prismjs"
import "prismjs/components/prism-javascript"
import "prismjs/components/prism-sql"
import "prismjs/components/prism-json"
import {format as formatSql} from "sql-formatter"

// LiveView hook that executes queries via the @supabase/postgrest-js client.
// Builds the standard postgrest-js chain (eq, order, limit, etc.), then appends
// any PgRest-specific custom params (e.g. ?search=Phoenix) onto the URL.
// PgRest separates these from standard filters and exposes them as custom_params.
const SupabaseQuery = {
  mounted() {
    this.handleEvent("execute", ({table, select, chain, params}) => {
      let serverMs = null
      let sql = null

      const timedFetch = (input, init) =>
        fetch(input, init).then(res => {
          const st = res.headers.get("server-timing")
          if (st) {
            const match = st.match(/dur=([\d.]+)/)
            if (match) serverMs = parseFloat(match[1])
          }
          const rawSql = res.headers.get("x-debug-sql")
          sql = rawSql ? atob(rawSql) : null
          return res
        })

      const postgrest = new PostgrestClient(window.location.origin + "/api", {
        fetch: timedFetch
      })

      let query = postgrest.from(table).select(select || "*")

      for (const [method, args] of chain) {
        query = query[method](...args)
      }

      if (params) {
        for (const [key, value] of Object.entries(params)) {
          query.url.searchParams.set(key, value)
        }
      }

      const start = performance.now()

      query.then(({data, error}) => {
        const clientMs = Math.round(performance.now() - start)
        const timing = {client_ms: clientMs, server_ms: serverMs ? Math.round(serverMs * 10) / 10 : null}

        let formattedQueries = []
        if (sql) {
          try {
            formattedQueries = sql.split("\n---\n")
              .map(s => formatSql(s, {language: "postgresql", tabWidth: 2}).trimStart())
          } catch (_) {
            formattedQueries = [sql]
          }
        }

        const payload = {timing: timing, queries: formattedQueries}
        if (error) {
          this.pushEvent("query_result", {...payload, error: error})
        } else {
          this.pushEvent("query_result", {...payload, data: data})
        }
      })
    })
  }
}

const Highlight = {
  mounted() { this.highlight() },
  updated() { this.highlight() },
  highlight() {
    this.el.querySelectorAll("code[class*='language-']").forEach(el => {
      Prism.highlightElement(el)
    })
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, SupabaseQuery, Highlight},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

