/**
 * Minimalna atrapa DOM — tyle, ile realnie używa adapter Meet.
 * Świadomie bez jsdom: repo ma zostać zero-dependency.
 *
 * Obsługiwane selektory: listy rozdzielone przecinkiem, złożenia
 * `tag`, `.klasa`, `[attr]`, `[attr="wartość"]`. Bez kombinatorów.
 */

class FakeElement {
  constructor(tag, attrs = {}, children = []) {
    this.tagName = String(tag).toUpperCase();
    this.attrs = { ...attrs };
    this.children = [];
    this.parentElement = null;
    this.isConnected = true;
    this._text = attrs.text ?? null;
    delete this.attrs.text;
    for (const child of children) this.append(child);
  }

  append(child) {
    child.parentElement = this;
    this.children.push(child);
    return this;
  }

  remove() {
    const parent = this.parentElement;
    if (parent) parent.children = parent.children.filter((c) => c !== this);
    this.parentElement = null;
    const mark = (node) => {
      node.isConnected = false;
      node.children.forEach(mark);
    };
    mark(this);
    return this;
  }

  getAttribute(name) {
    return Object.prototype.hasOwnProperty.call(this.attrs, name) ? String(this.attrs[name]) : null;
  }

  setAttribute(name, value) {
    this.attrs[name] = value;
  }

  get textContent() {
    if (this._text != null) return this._text;
    return this.children.map((c) => c.textContent).join('');
  }

  set textContent(value) {
    this.children = [];
    this._text = value;
  }

  descendants() {
    const out = [];
    const walk = (node) => {
      for (const child of node.children) {
        out.push(child);
        walk(child);
      }
    };
    walk(this);
    return out;
  }

  matches(selector) {
    return parseSelectorList(selector).some((parts) => parts.every((p) => matchPart(this, p)));
  }

  querySelectorAll(selector) {
    return this.descendants().filter((el) => el.matches(selector));
  }

  querySelector(selector) {
    return this.querySelectorAll(selector)[0] ?? null;
  }
}

function matchPart(el, part) {
  if (part.tag && el.tagName !== part.tag) return false;
  if (part.class) {
    const cls = el.getAttribute('class') ?? '';
    if (!cls.split(/\s+/).includes(part.class)) return false;
  }
  if (part.attr) {
    const value = el.getAttribute(part.attr);
    if (value === null) return false;
    if (part.value != null && value !== part.value) return false;
  }
  return true;
}

function parseSelectorList(selector) {
  return String(selector)
    .split(',')
    .map((chunk) => parseCompound(chunk.trim()))
    .filter((parts) => parts.length);
}

function parseCompound(selector) {
  const parts = [];
  const re = /(\[[^\]]+\])|(\.[A-Za-z0-9_-]+)|([A-Za-z][A-Za-z0-9-]*)/g;
  let match;
  while ((match = re.exec(selector))) {
    if (match[1]) {
      const inner = match[1].slice(1, -1);
      const eq = inner.indexOf('=');
      if (eq === -1) parts.push({ attr: inner });
      else parts.push({ attr: inner.slice(0, eq), value: inner.slice(eq + 1).replace(/^["']|["']$/g, '') });
    } else if (match[2]) {
      parts.push({ class: match[2].slice(1) });
    } else {
      parts.push({ tag: match[3].toUpperCase() });
    }
  }
  return parts;
}

/** h('div', { class: 'x' }, [ h('span', { text: 'hi' }) ]) */
export function h(tag, attrs = {}, children = []) {
  return new FakeElement(tag, attrs, children);
}

/** Tekstowy liść w skrócie. */
export function t(tag, text, attrs = {}) {
  return new FakeElement(tag, { ...attrs, text });
}

export function makeDocument(root, { title = '', href = 'https://meet.google.com/abc-defg-hij' } = {}) {
  const doc = {
    title,
    location: { href },
    body: root,
    querySelector: (sel) => root.querySelector(sel),
    querySelectorAll: (sel) => root.querySelectorAll(sel),
  };
  return doc;
}

export { FakeElement };
