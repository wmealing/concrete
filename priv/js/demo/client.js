// Concrete client: hydration + action dispatch + re-render.
// Load order: runtime.js, client.js, then the compiled page bundle.
//
// Boot with Client.init(moduleName, containerId, stateJSON):
//  - deserializes the server's type-tagged hydration JSON into terms
//  - installs one delegated click listener on the container; clicks on
//    any [concrete-click] element dispatch that action
//  - renders via the compiled render/1 function (same template the
//    server rendered, so the markup replaces itself identically)
//
// Dispatch cycle: action name -> compiled Mod:action/3 -> new component
// map -> render/1 -> container.innerHTML. Full re-render for now; vdom
// diffing arrives with the Phase 5 runtime.

const Client = {
  module: null,
  component: null,
  container: null,

  // --- Wire format (matches concrete_serializer) ---

  deserialize(node) {
    switch (node.type) {
      case "atom":      return Type.atom(node.value);
      case "integer":   return Type.integer(node.value);
      case "float":     return Type.float(node.value);
      case "bitstring": return Type.bitstring(Client.decodeBase64(node.value));
      case "tuple":     return Type.tuple(node.data.map(Client.deserialize));
      case "list":      return Type.list(node.data.map(Client.deserialize));
      case "map":
        return Type.map(node.data.map(([k, v]) =>
          [Client.deserialize(k), Client.deserialize(v)]));
      default:
        throw new Error(`cannot deserialize wire type: ${node.type}`);
    }
  },

  decodeBase64(b64) {
    if (typeof atob !== "undefined") return atob(b64);
    return Buffer.from(b64, "base64").toString("latin1");
  },

  // --- Lifecycle ---

  init(moduleName, containerId, stateJSON) {
    Client.module = moduleName;
    Client.container = document.getElementById(containerId);
    const wire = typeof stateJSON === "string" ? JSON.parse(stateJSON) : stateJSON;
    Client.component = Client.deserialize(wire);
    Client.container.addEventListener("click", (e) => {
      const el = e.target.closest("[concrete-click]");
      if (el) {
        e.preventDefault();
        Client.dispatch(el.getAttribute("concrete-click"));
      }
    });
    Client.render();
  },

  dispatch(actionName, params) {
    Client.component = Interpreter.call(Client.module, "action", 3, [
      Type.atom(actionName),
      params || Type.map([]),
      Client.component,
    ]);
    Client.render();
  },

  render() {
    const state =
      Interpreter.mapLookup(Client.component, Type.atom("state")) || Type.map([]);
    const dom = Interpreter.call(Client.module, "render", 1, [state]);
    Client.container.innerHTML = Client.domToHtml(dom);
  },

  // --- DOM AST terms -> HTML ---

  voidElements: new Set([
    "area", "base", "br", "col", "embed", "hr", "img", "input",
    "link", "meta", "param", "source", "track", "wbr",
  ]),

  domToHtml(node) {
    if (node.type === "list") return node.data.map(Client.domToHtml).join("");
    const [tag, ...rest] = node.data;
    switch (tag.value) {
      case "text":
        return rest[0].value; // static template text, emitted verbatim
      case "expr":
        return Client.escapeHtml(Client.termToText(rest[0]));
      case "element": {
        const [name, attrs, children] = rest;
        const attrsHtml = attrs.data
          .map((pair) =>
            ` ${pair.data[0].value}="${Client.escapeHtml(Client.termToText(pair.data[1]))}"`)
          .join("");
        if (Client.voidElements.has(name.value)) {
          return `<${name.value}${attrsHtml}>`;
        }
        return `<${name.value}${attrsHtml}>` +
               Client.domToHtml(children) +
               `</${name.value}>`;
      }
      case "component":
        throw new Error(
          "client-side component embedding is not supported yet (Phase 5)");
      case "slot":
        throw new Error(
          "client-side layout re-rendering is not supported yet (Phase 5)");
      default:
        throw new Error(`unknown DOM node tag: ${tag.value}`);
    }
  },

  termToText(t) {
    switch (t.type) {
      case "bitstring": return t.value;
      case "integer":
      case "float":     return String(t.value);
      case "atom":      return t.value;
      default:          return termToString(t);
    }
  },

  escapeHtml(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;")
            .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  },
};

window.Client = Client;
