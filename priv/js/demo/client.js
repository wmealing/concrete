// Concrete client: hydration + action dispatch + re-render.
// Load order: runtime.js, client.js, then the compiled page bundle.
//
// Boot with Client.init(moduleName, containerId, stateJSON):
//  - deserializes the server's type-tagged hydration JSON into terms
//  - installs one delegated click listener on the container: clicks on
//    any [concrete-click] element dispatch that action (client-only,
//    runs Mod:action/3 in the browser); clicks on any [concrete-command]
//    element dispatch that command (a server round trip over the
//    existing /concrete/command endpoint -- see dispatchCommand)
//  - renders via the compiled render/1 function (same template the
//    server rendered, so the markup replaces itself identically)
//
// Action dispatch cycle: action name -> compiled Mod:action/3 -> new
// component map -> render/1 -> diff against the previous render's
// vnode tree -> patch only what changed into the real DOM (see "Vnode
// diffing" below). Client.renderWithLayout (layouts are never part of
// this reactive loop -- see its own comment) still goes through the
// older, simpler domToHtml string renderer instead.
//
// Command dispatch cycle: command name -> POST {module, command,
// params, state: <wire-encoded Client.server>} to /concrete/command ->
// Mod:command/3 runs server-side -> the response's new Server map is
// merged into the component's own state (so whatever the command
// changed shows up through the normal render/1 path) -> render/1 runs
// same as after an action.

const Client = {
  module: null,
  component: null,
  container: null,
  vnodes: null, // the previous render's vnode tree, or null before the first render
  server: null, // Server map threaded through command round trips (opaque to render/1)

  // --- Wire format (matches concrete_serializer / concrete_deserializer) ---

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

  // Inverse of deserialize -- needed here (unlike the server, which
  // only ever sends wire JSON, never receives it) because a command
  // round trip has to send Client.server back up wire-encoded, the
  // same shape concrete_deserializer expects on the other end.
  serialize(term) {
    switch (term.type) {
      case "atom":      return { type: "atom", value: term.value };
      case "integer":   return { type: "integer", value: term.value };
      case "float":     return { type: "float", value: term.value };
      case "bitstring": return { type: "bitstring", value: Client.encodeBase64(term.value) };
      case "tuple":     return { type: "tuple", data: term.data.map(Client.serialize) };
      case "list":      return { type: "list", data: term.data.map(Client.serialize), tail: null };
      case "map":
        return {
          type: "map",
          data: term.data.map(([k, v]) => [Client.serialize(k), Client.serialize(v)]),
        };
      default:
        throw new Error(`cannot serialize term type: ${term.type}`);
    }
  },

  encodeBase64(s) {
    if (typeof btoa !== "undefined") return btoa(s);
    return Buffer.from(s, "latin1").toString("base64");
  },

  // --- Lifecycle ---

  init(moduleName, containerId, stateJSON) {
    Client.module = moduleName;
    Client.container = document.getElementById(containerId);
    const wire = typeof stateJSON === "string" ? JSON.parse(stateJSON) : stateJSON;
    Client.component = Client.deserialize(wire);
    Client.server = Type.map([]);
    Client.container.addEventListener("click", (e) => {
      const actionEl = e.target.closest("[concrete-click]");
      if (actionEl) {
        e.preventDefault();
        Client.dispatch(actionEl.getAttribute("concrete-click"));
        return;
      }
      const commandEl = e.target.closest("[concrete-command]");
      if (commandEl) {
        e.preventDefault();
        Client.dispatchCommand(commandEl.getAttribute("concrete-command"));
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

  // Declarative command dispatch: POSTs to the same /concrete/command
  // endpoint concrete_command_handler already serves, in the same wire
  // format (module/command/params plain, state wire-encoded) it
  // already expects -- this is a second way to reach that endpoint,
  // not a new one. params is a plain object (JSON, not wire-tagged),
  // matching how concrete_command_handler hands Params straight to
  // Mod:command/3 with no decode step; a template attribute has no
  // natural place to declare structured params, so this always sends
  // {} -- call dispatchCommand directly with real params from compiled
  // action code for anything that needs them.
  dispatchCommand(commandName, params) {
    return fetch("/concrete/command", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        module: Client.module,
        command: commandName,
        params: params || {},
        state: Client.serialize(Client.server),
      }),
    })
      .then((res) => res.json())
      .then((json) => {
        Client.server = Client.deserialize(json.state);
        // The command ran server-side against Server, not Component --
        // merge whatever it returned into the component's own state so
        // render/1 (which only ever sees Component) picks it up.
        const oldState =
          Interpreter.mapLookup(Client.component, Type.atom("state")) || Type.map([]);
        const mergedState = Interpreter.mapUpdate(oldState, Client.server.data);
        Client.component =
          Interpreter.mapUpdate(Client.component, [[Type.atom("state"), mergedState]]);
        Client.render();
      });
  },

  render() {
    const state =
      Interpreter.mapLookup(Client.component, Type.atom("state")) || Type.map([]);
    const dom = Interpreter.call(Client.module, "render", 1, [state]);
    const newVnodes = Client.buildVNodeList(dom);
    if (Client.vnodes === null) {
      // First render: the container already holds the server-rendered
      // HTML (that's the point of hydration), so it's cleared and
      // rebuilt from freshly created DOM nodes matching newVnodes once,
      // rather than diffed against nothing. Every render after this one
      // patches in place instead.
      Client.container.innerHTML = "";
      for (const v of newVnodes) Client.container.appendChild(Client.createDomNode(v));
    } else {
      Client.patchChildren(Client.container, Client.vnodes, newVnodes);
    }
    Client.vnodes = newVnodes;
  },

  // Renders a layout module's own template with pageHtml (already-
  // rendered markup, typically from Client.domToHtml on a page's own
  // render/1 output) spliced in wherever <slot /> appears -- the
  // client-side equivalent of concrete_renderer:wrap_in_layout/2.
  // Client.init/dispatch don't call this: they keep re-rendering only
  // the page's own content into its mount point, same as always, since
  // the layout shell around that mount point is already static HTML
  // from the initial server render. This exists so a bundle that
  // includes a layout module (see rebar_compiler_concrete's layout
  // discovery) has a real, working way to render it, for callers that
  // want the whole tree client-side.
  renderWithLayout(layoutModuleName, layoutState, pageHtml) {
    const layoutDom = Interpreter.call(layoutModuleName, "render", 1, [layoutState]);
    return Client.domToHtml(layoutDom, pageHtml);
  },

  // --- DOM AST terms -> HTML ---

  voidElements: new Set([
    "area", "base", "br", "col", "embed", "hr", "img", "input",
    "link", "meta", "param", "source", "track", "wbr",
  ]),

  // slotHtml is only ever set by renderWithLayout, and only threaded
  // through element children -- a <:component>'s own template starts a
  // fresh slot context (it can't see its parent's slot), matching
  // concrete_renderer:render_node/3's the same way server-side.
  domToHtml(node, slotHtml) {
    if (node.type === "list") {
      return node.data.map((n) => Client.domToHtml(n, slotHtml)).join("");
    }
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
               Client.domToHtml(children, slotHtml) +
               `</${name.value}>`;
      }
      case "component": {
        const childDom = Client.resolveComponentDom(rest[0], rest[1]);
        return Client.domToHtml(childDom); // fresh slot context -- no slotHtml passed
      }
      case "slot":
        if (slotHtml === undefined) {
          throw new Error("slot rendered outside a layout context");
        }
        return slotHtml;
      default:
        throw new Error(`unknown DOM node tag: ${tag.value}`);
    }
  },

  // A <:component> tag's compiled DOM node is
  // [Type.atom("component"), Type.atom(moduleName), Type.list([Type.tuple([key, value]), ...])].
  // Prop values are already fully evaluated Type terms -- the encoder
  // inlines each prop's compiled expression directly into this list
  // literal inside the parent's own render/1, so by the time render/1
  // returns, there's nothing left to evaluate here. Shared by both
  // domToHtml and the vnode builder below -- resolving a component
  // means running its init/2 then render/1, the same regardless of
  // which renderer consumes the result.
  resolveComponentDom(modAtom, propsListTerm) {
    const modName = modAtom.value;
    const propsMap = Type.map(propsListTerm.data.map((pair) => pair.data));
    const initResult = Interpreter.call(modName, "init", 2, [propsMap, Type.map([])]);
    const childComponent = initResult.data[0]; // {Component, Server} -> Component
    const childState =
      Interpreter.mapLookup(childComponent, Type.atom("state")) || Type.map([]);
    return Interpreter.call(modName, "render", 1, [childState]);
  },

  // --- Vnode diffing ---
  //
  // A vnode is either { kind: "text", text } or
  // { kind: "element", tag, attrs, children: vnode[] } -- "text" and
  // "expr" DOM AST nodes both normalize to the "text" vnode kind, since
  // by the time render/1 has evaluated an {expr, _} node there's no
  // remaining distinction (and using real Text nodes means the DOM
  // itself handles escaping -- no HTML-escaping step needed here, unlike
  // domToHtml's string path). A <:component> tag expands in place into
  // zero or more of its own resolved vnodes (it isn't a DOM element
  // itself, so it can't become one node -- same flattening domToHtml
  // does by concatenating strings). buildVNodeList/buildVNode never see
  // a "slot" node: layout rendering (renderWithLayout) doesn't go
  // through this path -- see its own comment.

  buildVNodeList(domList) {
    return domList.data.flatMap((n) => Client.buildVNode(n));
  },

  buildVNode(node) {
    const [tag, ...rest] = node.data;
    switch (tag.value) {
      case "text":
        return [{ kind: "text", text: rest[0].value }];
      case "expr":
        return [{ kind: "text", text: Client.termToText(rest[0]) }];
      case "element": {
        const [name, attrs, children] = rest;
        const attrsObj = {};
        for (const pair of attrs.data) {
          attrsObj[pair.data[0].value] = Client.termToText(pair.data[1]);
        }
        return [{
          kind: "element",
          tag: name.value,
          attrs: attrsObj,
          children: Client.buildVNodeList(children),
        }];
      }
      case "component":
        return Client.buildVNodeList(Client.resolveComponentDom(rest[0], rest[1]));
      case "slot":
        throw new Error("slot rendered outside a layout context");
      default:
        throw new Error(`unknown DOM node tag: ${tag.value}`);
    }
  },

  createDomNode(v) {
    if (v.kind === "text") return document.createTextNode(v.text);
    const el = document.createElement(v.tag);
    for (const [name, value] of Object.entries(v.attrs)) el.setAttribute(name, value);
    for (const child of v.children) el.appendChild(Client.createDomNode(child));
    return el;
  },

  // Same element, same tag -> patch its attrs and children in place and
  // keep the DOM node; anything else (different kind, or an element
  // that changed tag) -> the node is replaced wholesale, same as a
  // browser-native vdom library would do.
  patchNode(domNode, oldV, newV) {
    if (oldV.kind !== newV.kind || (newV.kind === "element" && oldV.tag !== newV.tag)) {
      const fresh = Client.createDomNode(newV);
      domNode.parentNode.replaceChild(fresh, domNode);
      return;
    }
    if (newV.kind === "text") {
      if (oldV.text !== newV.text) domNode.textContent = newV.text;
      return;
    }
    Client.patchAttrs(domNode, oldV.attrs, newV.attrs);
    Client.patchChildren(domNode, oldV.children, newV.children);
  },

  patchAttrs(el, oldAttrs, newAttrs) {
    for (const name of Object.keys(oldAttrs)) {
      if (!(name in newAttrs)) el.removeAttribute(name);
    }
    for (const [name, value] of Object.entries(newAttrs)) {
      if (oldAttrs[name] !== value) el.setAttribute(name, value);
    }
  },

  // Index-based, keyless reconciliation: appends cover growth, the
  // trailing-removal pass covers shrinkage, and the overlapping region
  // in between is patched node-for-node in place. That's enough for
  // templates without list-driven reordering; nothing in the template
  // language (no keyed loops) produces a case this would handle wrong,
  // and it's a lot simpler than keyed diffing.
  patchChildren(parentDom, oldVNodes, newVNodes) {
    const newLen = newVNodes.length;
    for (let i = 0; i < newLen; i++) {
      if (i >= oldVNodes.length) {
        parentDom.appendChild(Client.createDomNode(newVNodes[i]));
      } else {
        Client.patchNode(parentDom.childNodes[i], oldVNodes[i], newVNodes[i]);
      }
    }
    while (parentDom.childNodes.length > newLen) {
      parentDom.removeChild(parentDom.lastChild);
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
