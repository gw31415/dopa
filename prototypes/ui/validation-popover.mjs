const GAP = 8;
const VIEWPORT_INSET = 12;
const FALLBACK_WIDTH = 248;
const NOT_DISMISSED = Symbol('not-dismissed');

function toText(value) {
  return value == null ? '' : String(value);
}

function sameKey(left, right) {
  return Object.is(left, right);
}

function isInside(node, target) {
  if (!node || !target) return false;
  return node === target || (typeof node.contains === 'function' && node.contains(target));
}

function cssPixels(value) {
  const rounded = Math.round(value * 100) / 100;
  return `${rounded}px`;
}

function clamp(value, minimum, maximum) {
  return Math.min(Math.max(value, minimum), maximum);
}

export function createValidationPopover(element, anchors = []) {
  const anchorList = Array.from(anchors || []).filter(Boolean);
  const ownerDocument = element?.ownerDocument || globalThis.document;
  const ownerWindow = ownerDocument?.defaultView || globalThis.window;
  const titleElement = element?.querySelector?.('#validation-title');
  const messageElement = element?.querySelector?.('#edit-error');
  const dismissButton = element?.querySelector?.('#dismiss-validation');

  let current = {
    anchor: null,
    title: '',
    message: '',
    key: undefined,
    visible: false,
  };
  let dismissedKey = NOT_DISMISSED;
  let popoverOpen = false;
  let suppressedFocusAnchor = null;

  function hasMessage(state = current) {
    return state.visible && !!state.anchor && state.message.trim().length > 0;
  }

  function isOpen() {
    if (popoverOpen) return true;
    if (typeof element?.matches === 'function') {
      try {
        if (element.matches(':popover-open')) {
          popoverOpen = true;
          return true;
        }
      } catch {
        // Older browsers do not recognize :popover-open.
      }
    }
    return false;
  }

  function closePopover() {
    if (!element || !isOpen()) {
      popoverOpen = false;
      return;
    }
    try {
      if (typeof element.hidePopover === 'function') element.hidePopover();
      else if (typeof element.close === 'function') element.close();
      else if ('hidden' in element) element.hidden = true;
    } catch {
      // The element can already have been removed or closed by the browser.
    }
    popoverOpen = false;
  }

  function viewportSize() {
    const visualViewport = ownerWindow?.visualViewport;
    const width = Number(ownerWindow?.innerWidth) || Number(visualViewport?.width) ||
      Number(ownerDocument?.documentElement?.clientWidth);
    const height = Number(ownerWindow?.innerHeight) || Number(visualViewport?.height) ||
      Number(ownerDocument?.documentElement?.clientHeight);
    return {
      width: width > 0 ? width : Number.POSITIVE_INFINITY,
      height: height > 0 ? height : Number.POSITIVE_INFINITY,
    };
  }

  function computedWidth() {
    const rect = element?.getBoundingClientRect?.();
    if (rect?.width > 0) return rect.width;
    const computedStyle = ownerWindow?.getComputedStyle?.(element);
    const width = Number.parseFloat(computedStyle?.width || '');
    return width > 0 ? width : FALLBACK_WIDTH;
  }

  function computedHeight() {
    const rect = element?.getBoundingClientRect?.();
    if (rect?.height > 0) return rect.height;
    if (element?.offsetHeight > 0) return element.offsetHeight;
    const computedStyle = ownerWindow?.getComputedStyle?.(element);
    const height = Number.parseFloat(computedStyle?.height || '');
    return height > 0 ? height : 0;
  }

  function reposition() {
    if (!element || !hasMessage() || !isOpen()) return;
    const anchorRect = current.anchor?.getBoundingClientRect?.();
    if (!anchorRect) return;

    const width = computedWidth();
    const height = computedHeight();
    const {width: viewportWidth} = viewportSize();
    const desiredLeft = anchorRect.right - width;
    const maximumLeft = Math.max(VIEWPORT_INSET, viewportWidth - VIEWPORT_INSET - width);
    const left = Number.isFinite(viewportWidth)
      ? clamp(desiredLeft, VIEWPORT_INSET, maximumLeft)
      : desiredLeft;
    const aboveTop = anchorRect.top - height - GAP;
    const placement = aboveTop >= VIEWPORT_INSET ? 'above' : 'below';
    const top = placement === 'above' ? aboveTop : anchorRect.bottom + GAP;
    const anchorCenter = anchorRect.left + (anchorRect.width / 2);
    const arrowX = clamp(anchorCenter - left, 12, Math.max(12, width - 12));

    element.style.left = cssPixels(left);
    element.style.top = cssPixels(top);
    element.style.setProperty?.('--arrow-x', cssPixels(arrowX));
    element.dataset.placement = placement;
  }

  function showPopover() {
    if (!element || isOpen()) {
      reposition();
      return;
    }
    try {
      if (typeof element.showPopover === 'function') element.showPopover();
      else if ('hidden' in element) element.hidden = false;
      popoverOpen = true;
    } catch {
      popoverOpen = false;
      return;
    }
    reposition();
  }

  function setText(node, value) {
    if (node && node.textContent !== value) node.textContent = value;
  }

  function focusAnchor(anchor) {
    if (!anchor || typeof anchor.focus !== 'function') return;
    if (ownerDocument?.activeElement === anchor) return;
    suppressedFocusAnchor = anchor;
    try {
      anchor.focus({preventScroll: true});
    } catch {
      anchor.focus();
    }
    const clearSuppression = globalThis.queueMicrotask || (callback => Promise.resolve().then(callback));
    clearSuppression(() => {
      if (suppressedFocusAnchor === anchor) suppressedFocusAnchor = null;
    });
  }

  function dismiss({restoreFocus = false} = {}) {
    if (hasMessage()) dismissedKey = current.key;
    closePopover();
    if (restoreFocus) focusAnchor(current.anchor);
  }

  function activateAnchor(anchor) {
    if (anchor !== current.anchor || !hasMessage()) return;
    dismissedKey = NOT_DISMISSED;
    showPopover();
  }

  function attachListeners() {
    if (!element) return;
    dismissButton?.addEventListener?.('click', event => {
      event.preventDefault();
      dismiss({restoreFocus: true});
    });

    ownerDocument?.addEventListener?.('keydown', event => {
      if (event.key !== 'Escape' || !isOpen() || !hasMessage()) return;
      event.preventDefault();
      dismiss({restoreFocus: true});
    }, true);
    ownerDocument?.addEventListener?.('pointerdown', event => {
      if (!hasMessage()) return;
      if (isInside(element, event.target) || isInside(current.anchor, event.target)) return;
      dismiss();
    }, true);

    for (const anchor of anchorList) {
      anchor.addEventListener?.('focus', () => {
        if (suppressedFocusAnchor === anchor) {
          suppressedFocusAnchor = null;
          return;
        }
        activateAnchor(anchor);
      });
      anchor.addEventListener?.('click', () => activateAnchor(anchor));
      anchor.addEventListener?.('input', () => activateAnchor(anchor));
    }

    ownerWindow?.addEventListener?.('resize', reposition, {passive: true});
    ownerWindow?.addEventListener?.('scroll', reposition, {capture: true, passive: true});
    ownerWindow?.visualViewport?.addEventListener?.('resize', reposition, {passive: true});
    ownerWindow?.visualViewport?.addEventListener?.('scroll', reposition, {passive: true});

    const ResizeObserverConstructor = ownerWindow?.ResizeObserver || globalThis.ResizeObserver;
    if (typeof ResizeObserverConstructor === 'function') {
      const observer = new ResizeObserverConstructor(reposition);
      try {
        observer.observe(element);
        for (const anchor of anchorList) observer.observe(anchor);
      } catch {
        observer.disconnect?.();
      }
    }
    element.addEventListener?.('toggle', event => {
      popoverOpen = event.newState === 'open';
    });
  }

  attachListeners();

  return {
    update({anchor = null, title = '', message = '', key, visible = false} = {}) {
      const previous = current;
      current = {
        anchor,
        title: toText(title),
        message: toText(message),
        key,
        visible: visible === true,
      };

      setText(titleElement, current.title);
      setText(messageElement, current.message);
      if (messageElement && messageElement.hidden !== !current.message) {
        messageElement.hidden = !current.message;
      }

      if (!hasMessage()) {
        closePopover();
        dismissedKey = NOT_DISMISSED;
        return;
      }

      const previousWasActive = hasMessage(previous);
      if (!previousWasActive || previous.anchor !== current.anchor ||
          !sameKey(previous.key, current.key)) {
        dismissedKey = NOT_DISMISSED;
      }

      if (sameKey(dismissedKey, current.key)) {
        reposition();
        return;
      }
      showPopover();
    },
  };
}
