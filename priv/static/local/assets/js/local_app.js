(() => {
  var __create = Object.create;
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __getProtoOf = Object.getPrototypeOf;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __commonJS = (cb, mod) => function __require() {
    return mod || (0, cb[__getOwnPropNames(cb)[0]])((mod = { exports: {} }).exports, mod), mod.exports;
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
    // If the importer is in node compatibility mode or this is not an ESM
    // file that has been converted to a CommonJS file using a Babel-
    // compatible transform (i.e. "__esModule" has not been set), then set
    // "default" to the CommonJS "module.exports" for node compatibility.
    isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
    mod
  ));

  // vendor/Sortable.min.js
  var require_Sortable_min = __commonJS({
    "vendor/Sortable.min.js"(exports, module) {
      !function(t, e) {
        "object" == typeof exports && "undefined" != typeof module ? module.exports = e() : "function" == typeof define && define.amd ? define(e) : (t = t || self).Sortable = e();
      }(exports, function() {
        "use strict";
        function e(e2, t2) {
          var n2, o2 = Object.keys(e2);
          return Object.getOwnPropertySymbols && (n2 = Object.getOwnPropertySymbols(e2), t2 && (n2 = n2.filter(function(t3) {
            return Object.getOwnPropertyDescriptor(e2, t3).enumerable;
          })), o2.push.apply(o2, n2)), o2;
        }
        function I(o2) {
          for (var t2 = 1; t2 < arguments.length; t2++) {
            var i2 = null != arguments[t2] ? arguments[t2] : {};
            t2 % 2 ? e(Object(i2), true).forEach(function(t3) {
              var e2, n2;
              e2 = o2, t3 = i2[n2 = t3], n2 in e2 ? Object.defineProperty(e2, n2, { value: t3, enumerable: true, configurable: true, writable: true }) : e2[n2] = t3;
            }) : Object.getOwnPropertyDescriptors ? Object.defineProperties(o2, Object.getOwnPropertyDescriptors(i2)) : e(Object(i2)).forEach(function(t3) {
              Object.defineProperty(o2, t3, Object.getOwnPropertyDescriptor(i2, t3));
            });
          }
          return o2;
        }
        function o(t2) {
          return (o = "function" == typeof Symbol && "symbol" == typeof Symbol.iterator ? function(t3) {
            return typeof t3;
          } : function(t3) {
            return t3 && "function" == typeof Symbol && t3.constructor === Symbol && t3 !== Symbol.prototype ? "symbol" : typeof t3;
          })(t2);
        }
        function a() {
          return (a = Object.assign || function(t2) {
            for (var e2 = 1; e2 < arguments.length; e2++) {
              var n2, o2 = arguments[e2];
              for (n2 in o2) Object.prototype.hasOwnProperty.call(o2, n2) && (t2[n2] = o2[n2]);
            }
            return t2;
          }).apply(this, arguments);
        }
        function i(t2, e2) {
          if (null == t2) return {};
          var n2, o2 = function(t3, e3) {
            if (null == t3) return {};
            for (var n3, o3 = {}, i3 = Object.keys(t3), r3 = 0; r3 < i3.length; r3++) n3 = i3[r3], 0 <= e3.indexOf(n3) || (o3[n3] = t3[n3]);
            return o3;
          }(t2, e2);
          if (Object.getOwnPropertySymbols) for (var i2 = Object.getOwnPropertySymbols(t2), r2 = 0; r2 < i2.length; r2++) n2 = i2[r2], 0 <= e2.indexOf(n2) || Object.prototype.propertyIsEnumerable.call(t2, n2) && (o2[n2] = t2[n2]);
          return o2;
        }
        function r(t2) {
          return function(t3) {
            if (Array.isArray(t3)) return l(t3);
          }(t2) || function(t3) {
            if ("undefined" != typeof Symbol && null != t3[Symbol.iterator] || null != t3["@@iterator"]) return Array.from(t3);
          }(t2) || function(t3, e2) {
            if (t3) {
              if ("string" == typeof t3) return l(t3, e2);
              var n2 = Object.prototype.toString.call(t3).slice(8, -1);
              return "Map" === (n2 = "Object" === n2 && t3.constructor ? t3.constructor.name : n2) || "Set" === n2 ? Array.from(t3) : "Arguments" === n2 || /^(?:Ui|I)nt(?:8|16|32)(?:Clamped)?Array$/.test(n2) ? l(t3, e2) : void 0;
            }
          }(t2) || function() {
            throw new TypeError("Invalid attempt to spread non-iterable instance.\nIn order to be iterable, non-array objects must have a [Symbol.iterator]() method.");
          }();
        }
        function l(t2, e2) {
          (null == e2 || e2 > t2.length) && (e2 = t2.length);
          for (var n2 = 0, o2 = new Array(e2); n2 < e2; n2++) o2[n2] = t2[n2];
          return o2;
        }
        function t(t2) {
          if ("undefined" != typeof window && window.navigator) return !!navigator.userAgent.match(t2);
        }
        var y = t(/(?:Trident.*rv[ :]?11\.|msie|iemobile|Windows Phone)/i), w = t(/Edge/i), s = t(/firefox/i), u = t(/safari/i) && !t(/chrome/i) && !t(/android/i), c = t(/iP(ad|od|hone)/i), n = t(/chrome/i) && t(/android/i), d = { capture: false, passive: false };
        function h(t2, e2, n2) {
          t2.addEventListener(e2, n2, !y && d);
        }
        function p(t2, e2, n2) {
          t2.removeEventListener(e2, n2, !y && d);
        }
        function f(t2, e2) {
          if (e2 && (">" === e2[0] && (e2 = e2.substring(1)), t2)) try {
            if (t2.matches) return t2.matches(e2);
            if (t2.msMatchesSelector) return t2.msMatchesSelector(e2);
            if (t2.webkitMatchesSelector) return t2.webkitMatchesSelector(e2);
          } catch (t3) {
            return;
          }
        }
        function g(t2) {
          return t2.host && t2 !== document && t2.host.nodeType ? t2.host : t2.parentNode;
        }
        function P(t2, e2, n2, o2) {
          if (t2) {
            n2 = n2 || document;
            do {
              if (null != e2 && (">" !== e2[0] || t2.parentNode === n2) && f(t2, e2) || o2 && t2 === n2) return t2;
            } while (t2 !== n2 && (t2 = g(t2)));
          }
          return null;
        }
        var m, v = /\s+/g;
        function k(t2, e2, n2) {
          var o2;
          t2 && e2 && (t2.classList ? t2.classList[n2 ? "add" : "remove"](e2) : (o2 = (" " + t2.className + " ").replace(v, " ").replace(" " + e2 + " ", " "), t2.className = (o2 + (n2 ? " " + e2 : "")).replace(v, " ")));
        }
        function R(t2, e2, n2) {
          var o2 = t2 && t2.style;
          if (o2) {
            if (void 0 === n2) return document.defaultView && document.defaultView.getComputedStyle ? n2 = document.defaultView.getComputedStyle(t2, "") : t2.currentStyle && (n2 = t2.currentStyle), void 0 === e2 ? n2 : n2[e2];
            o2[e2 = !(e2 in o2 || -1 !== e2.indexOf("webkit")) ? "-webkit-" + e2 : e2] = n2 + ("string" == typeof n2 ? "" : "px");
          }
        }
        function b(t2, e2) {
          var n2 = "";
          if ("string" == typeof t2) n2 = t2;
          else do {
            var o2 = R(t2, "transform");
          } while (o2 && "none" !== o2 && (n2 = o2 + " " + n2), !e2 && (t2 = t2.parentNode));
          var i2 = window.DOMMatrix || window.WebKitCSSMatrix || window.CSSMatrix || window.MSCSSMatrix;
          return i2 && new i2(n2);
        }
        function D(t2, e2, n2) {
          if (t2) {
            var o2 = t2.getElementsByTagName(e2), i2 = 0, r2 = o2.length;
            if (n2) for (; i2 < r2; i2++) n2(o2[i2], i2);
            return o2;
          }
          return [];
        }
        function O() {
          var t2 = document.scrollingElement;
          return t2 || document.documentElement;
        }
        function X(t2, e2, n2, o2, i2) {
          if (t2.getBoundingClientRect || t2 === window) {
            var r2, a2, l2, s2, c2, u2, d2 = t2 !== window && t2.parentNode && t2 !== O() ? (a2 = (r2 = t2.getBoundingClientRect()).top, l2 = r2.left, s2 = r2.bottom, c2 = r2.right, u2 = r2.height, r2.width) : (l2 = a2 = 0, s2 = window.innerHeight, c2 = window.innerWidth, u2 = window.innerHeight, window.innerWidth);
            if ((e2 || n2) && t2 !== window && (i2 = i2 || t2.parentNode, !y)) do {
              if (i2 && i2.getBoundingClientRect && ("none" !== R(i2, "transform") || n2 && "static" !== R(i2, "position"))) {
                var h2 = i2.getBoundingClientRect();
                a2 -= h2.top + parseInt(R(i2, "border-top-width")), l2 -= h2.left + parseInt(R(i2, "border-left-width")), s2 = a2 + r2.height, c2 = l2 + r2.width;
                break;
              }
            } while (i2 = i2.parentNode);
            return o2 && t2 !== window && (o2 = (e2 = b(i2 || t2)) && e2.a, t2 = e2 && e2.d, e2 && (s2 = (a2 /= t2) + (u2 /= t2), c2 = (l2 /= o2) + (d2 /= o2))), { top: a2, left: l2, bottom: s2, right: c2, width: d2, height: u2 };
          }
        }
        function Y(t2, e2, n2) {
          for (var o2 = M(t2, true), i2 = X(t2)[e2]; o2; ) {
            var r2 = X(o2)[n2];
            if (!("top" === n2 || "left" === n2 ? r2 <= i2 : i2 <= r2)) return o2;
            if (o2 === O()) break;
            o2 = M(o2, false);
          }
          return false;
        }
        function B(t2, e2, n2, o2) {
          for (var i2 = 0, r2 = 0, a2 = t2.children; r2 < a2.length; ) {
            if ("none" !== a2[r2].style.display && a2[r2] !== jt.ghost && (o2 || a2[r2] !== jt.dragged) && P(a2[r2], n2.draggable, t2, false)) {
              if (i2 === e2) return a2[r2];
              i2++;
            }
            r2++;
          }
          return null;
        }
        function F(t2, e2) {
          for (var n2 = t2.lastElementChild; n2 && (n2 === jt.ghost || "none" === R(n2, "display") || e2 && !f(n2, e2)); ) n2 = n2.previousElementSibling;
          return n2 || null;
        }
        function j(t2, e2) {
          var n2 = 0;
          if (!t2 || !t2.parentNode) return -1;
          for (; t2 = t2.previousElementSibling; ) "TEMPLATE" === t2.nodeName.toUpperCase() || t2 === jt.clone || e2 && !f(t2, e2) || n2++;
          return n2;
        }
        function E(t2) {
          var e2 = 0, n2 = 0, o2 = O();
          if (t2) do {
            var i2 = b(t2), r2 = i2.a, i2 = i2.d;
          } while (e2 += t2.scrollLeft * r2, n2 += t2.scrollTop * i2, t2 !== o2 && (t2 = t2.parentNode));
          return [e2, n2];
        }
        function M(t2, e2) {
          if (!t2 || !t2.getBoundingClientRect) return O();
          var n2 = t2, o2 = false;
          do {
            if (n2.clientWidth < n2.scrollWidth || n2.clientHeight < n2.scrollHeight) {
              var i2 = R(n2);
              if (n2.clientWidth < n2.scrollWidth && ("auto" == i2.overflowX || "scroll" == i2.overflowX) || n2.clientHeight < n2.scrollHeight && ("auto" == i2.overflowY || "scroll" == i2.overflowY)) {
                if (!n2.getBoundingClientRect || n2 === document.body) return O();
                if (o2 || e2) return n2;
                o2 = true;
              }
            }
          } while (n2 = n2.parentNode);
          return O();
        }
        function S(t2, e2) {
          return Math.round(t2.top) === Math.round(e2.top) && Math.round(t2.left) === Math.round(e2.left) && Math.round(t2.height) === Math.round(e2.height) && Math.round(t2.width) === Math.round(e2.width);
        }
        function _(e2, n2) {
          return function() {
            var t2;
            m || (1 === (t2 = arguments).length ? e2.call(this, t2[0]) : e2.apply(this, t2), m = setTimeout(function() {
              m = void 0;
            }, n2));
          };
        }
        function H(t2, e2, n2) {
          t2.scrollLeft += e2, t2.scrollTop += n2;
        }
        function C(t2) {
          var e2 = window.Polymer, n2 = window.jQuery || window.Zepto;
          return e2 && e2.dom ? e2.dom(t2).cloneNode(true) : n2 ? n2(t2).clone(true)[0] : t2.cloneNode(true);
        }
        function T(t2, e2) {
          R(t2, "position", "absolute"), R(t2, "top", e2.top), R(t2, "left", e2.left), R(t2, "width", e2.width), R(t2, "height", e2.height);
        }
        function x(t2) {
          R(t2, "position", ""), R(t2, "top", ""), R(t2, "left", ""), R(t2, "width", ""), R(t2, "height", "");
        }
        function L(n2, o2, i2) {
          var r2 = {};
          return Array.from(n2.children).forEach(function(t2) {
            var e2;
            P(t2, o2.draggable, n2, false) && !t2.animated && t2 !== i2 && (e2 = X(t2), r2.left = Math.min(null !== (t2 = r2.left) && void 0 !== t2 ? t2 : 1 / 0, e2.left), r2.top = Math.min(null !== (t2 = r2.top) && void 0 !== t2 ? t2 : 1 / 0, e2.top), r2.right = Math.max(null !== (t2 = r2.right) && void 0 !== t2 ? t2 : -1 / 0, e2.right), r2.bottom = Math.max(null !== (t2 = r2.bottom) && void 0 !== t2 ? t2 : -1 / 0, e2.bottom));
          }), r2.width = r2.right - r2.left, r2.height = r2.bottom - r2.top, r2.x = r2.left, r2.y = r2.top, r2;
        }
        var K = "Sortable" + (/* @__PURE__ */ new Date()).getTime();
        function A() {
          var e2, o2 = [];
          return { captureAnimationState: function() {
            o2 = [], this.options.animation && [].slice.call(this.el.children).forEach(function(t2) {
              var e3, n2;
              "none" !== R(t2, "display") && t2 !== jt.ghost && (o2.push({ target: t2, rect: X(t2) }), e3 = I({}, o2[o2.length - 1].rect), !t2.thisAnimationDuration || (n2 = b(t2, true)) && (e3.top -= n2.f, e3.left -= n2.e), t2.fromRect = e3);
            });
          }, addAnimationState: function(t2) {
            o2.push(t2);
          }, removeAnimationState: function(t2) {
            o2.splice(function(t3, e3) {
              for (var n2 in t3) if (t3.hasOwnProperty(n2)) {
                for (var o3 in e3) if (e3.hasOwnProperty(o3) && e3[o3] === t3[n2][o3]) return Number(n2);
              }
              return -1;
            }(o2, { target: t2 }), 1);
          }, animateAll: function(t2) {
            var c2 = this;
            if (!this.options.animation) return clearTimeout(e2), void ("function" == typeof t2 && t2());
            var u2 = false, d2 = 0;
            o2.forEach(function(t3) {
              var e3 = 0, n2 = t3.target, o3 = n2.fromRect, i2 = X(n2), r2 = n2.prevFromRect, a2 = n2.prevToRect, l2 = t3.rect, s2 = b(n2, true);
              s2 && (i2.top -= s2.f, i2.left -= s2.e), n2.toRect = i2, n2.thisAnimationDuration && S(r2, i2) && !S(o3, i2) && (l2.top - i2.top) / (l2.left - i2.left) == (o3.top - i2.top) / (o3.left - i2.left) && (t3 = l2, s2 = r2, r2 = a2, a2 = c2.options, e3 = Math.sqrt(Math.pow(s2.top - t3.top, 2) + Math.pow(s2.left - t3.left, 2)) / Math.sqrt(Math.pow(s2.top - r2.top, 2) + Math.pow(s2.left - r2.left, 2)) * a2.animation), S(i2, o3) || (n2.prevFromRect = o3, n2.prevToRect = i2, e3 = e3 || c2.options.animation, c2.animate(n2, l2, i2, e3)), e3 && (u2 = true, d2 = Math.max(d2, e3), clearTimeout(n2.animationResetTimer), n2.animationResetTimer = setTimeout(function() {
                n2.animationTime = 0, n2.prevFromRect = null, n2.fromRect = null, n2.prevToRect = null, n2.thisAnimationDuration = null;
              }, e3), n2.thisAnimationDuration = e3);
            }), clearTimeout(e2), u2 ? e2 = setTimeout(function() {
              "function" == typeof t2 && t2();
            }, d2) : "function" == typeof t2 && t2(), o2 = [];
          }, animate: function(t2, e3, n2, o3) {
            var i2, r2;
            o3 && (R(t2, "transition", ""), R(t2, "transform", ""), i2 = (r2 = b(this.el)) && r2.a, r2 = r2 && r2.d, i2 = (e3.left - n2.left) / (i2 || 1), r2 = (e3.top - n2.top) / (r2 || 1), t2.animatingX = !!i2, t2.animatingY = !!r2, R(t2, "transform", "translate3d(" + i2 + "px," + r2 + "px,0)"), this.forRepaintDummy = t2.offsetWidth, R(t2, "transition", "transform " + o3 + "ms" + (this.options.easing ? " " + this.options.easing : "")), R(t2, "transform", "translate3d(0,0,0)"), "number" == typeof t2.animated && clearTimeout(t2.animated), t2.animated = setTimeout(function() {
              R(t2, "transition", ""), R(t2, "transform", ""), t2.animated = false, t2.animatingX = false, t2.animatingY = false;
            }, o3));
          } };
        }
        var N = [], W = { initializeByDefault: true }, z = { mount: function(e2) {
          for (var t2 in W) !W.hasOwnProperty(t2) || t2 in e2 || (e2[t2] = W[t2]);
          N.forEach(function(t3) {
            if (t3.pluginName === e2.pluginName) throw "Sortable: Cannot mount plugin ".concat(e2.pluginName, " more than once");
          }), N.push(e2);
        }, pluginEvent: function(e2, n2, o2) {
          var t2 = this;
          this.eventCanceled = false, o2.cancel = function() {
            t2.eventCanceled = true;
          };
          var i2 = e2 + "Global";
          N.forEach(function(t3) {
            n2[t3.pluginName] && (n2[t3.pluginName][i2] && n2[t3.pluginName][i2](I({ sortable: n2 }, o2)), n2.options[t3.pluginName] && n2[t3.pluginName][e2] && n2[t3.pluginName][e2](I({ sortable: n2 }, o2)));
          });
        }, initializePlugins: function(n2, o2, i2, t2) {
          for (var e2 in N.forEach(function(t3) {
            var e3 = t3.pluginName;
            (n2.options[e3] || t3.initializeByDefault) && ((t3 = new t3(n2, o2, n2.options)).sortable = n2, t3.options = n2.options, n2[e3] = t3, a(i2, t3.defaults));
          }), n2.options) {
            var r2;
            n2.options.hasOwnProperty(e2) && (void 0 !== (r2 = this.modifyOption(n2, e2, n2.options[e2])) && (n2.options[e2] = r2));
          }
        }, getEventProperties: function(e2, n2) {
          var o2 = {};
          return N.forEach(function(t2) {
            "function" == typeof t2.eventProperties && a(o2, t2.eventProperties.call(n2[t2.pluginName], e2));
          }), o2;
        }, modifyOption: function(e2, n2, o2) {
          var i2;
          return N.forEach(function(t2) {
            e2[t2.pluginName] && t2.optionListeners && "function" == typeof t2.optionListeners[n2] && (i2 = t2.optionListeners[n2].call(e2[t2.pluginName], o2));
          }), i2;
        } };
        function G(t2) {
          var e2 = t2.sortable, n2 = t2.rootEl, o2 = t2.name, i2 = t2.targetEl, r2 = t2.cloneEl, a2 = t2.toEl, l2 = t2.fromEl, s2 = t2.oldIndex, c2 = t2.newIndex, u2 = t2.oldDraggableIndex, d2 = t2.newDraggableIndex, h2 = t2.originalEvent, p2 = t2.putSortable, f2 = t2.extraEventProperties;
          if (e2 = e2 || n2 && n2[K]) {
            var g2, m2 = e2.options, t2 = "on" + o2.charAt(0).toUpperCase() + o2.substr(1);
            !window.CustomEvent || y || w ? (g2 = document.createEvent("Event")).initEvent(o2, true, true) : g2 = new CustomEvent(o2, { bubbles: true, cancelable: true }), g2.to = a2 || n2, g2.from = l2 || n2, g2.item = i2 || n2, g2.clone = r2, g2.oldIndex = s2, g2.newIndex = c2, g2.oldDraggableIndex = u2, g2.newDraggableIndex = d2, g2.originalEvent = h2, g2.pullMode = p2 ? p2.lastPutMode : void 0;
            var v2, b2 = I(I({}, f2), z.getEventProperties(o2, e2));
            for (v2 in b2) g2[v2] = b2[v2];
            n2 && n2.dispatchEvent(g2), m2[t2] && m2[t2].call(e2, g2);
          }
        }
        function U(t2, e2) {
          var n2 = (o2 = 2 < arguments.length && void 0 !== arguments[2] ? arguments[2] : {}).evt, o2 = i(o2, q);
          z.pluginEvent.bind(jt)(t2, e2, I({ dragEl: Z, parentEl: $, ghostEl: Q, rootEl: J, nextEl: tt, lastDownEl: et, cloneEl: nt, cloneHidden: ot, dragStarted: mt, putSortable: ct, activeSortable: jt.active, originalEvent: n2, oldIndex: it, oldDraggableIndex: at, newIndex: rt, newDraggableIndex: lt, hideGhostForTarget: Xt, unhideGhostForTarget: Yt, cloneNowHidden: function() {
            ot = true;
          }, cloneNowShown: function() {
            ot = false;
          }, dispatchSortableEvent: function(t3) {
            V({ sortable: e2, name: t3, originalEvent: n2 });
          } }, o2));
        }
        var q = ["evt"];
        function V(t2) {
          G(I({ putSortable: ct, cloneEl: nt, targetEl: Z, rootEl: J, oldIndex: it, oldDraggableIndex: at, newIndex: rt, newDraggableIndex: lt }, t2));
        }
        var Z, $, Q, J, tt, et, nt, ot, it, rt, at, lt, st, ct, ut, dt, ht, pt, ft, gt, mt, vt, bt, yt, wt, Dt = false, Et = false, St = [], _t = false, Ct = false, Tt = [], xt = false, Ot = [], Mt = "undefined" != typeof document, At = c, Nt = w || y ? "cssFloat" : "float", It = Mt && !n && !c && "draggable" in document.createElement("div"), Pt = function() {
          if (Mt) {
            if (y) return false;
            var t2 = document.createElement("x");
            return t2.style.cssText = "pointer-events:auto", "auto" === t2.style.pointerEvents;
          }
        }(), kt = function(t2, e2) {
          var n2 = R(t2), o2 = parseInt(n2.width) - parseInt(n2.paddingLeft) - parseInt(n2.paddingRight) - parseInt(n2.borderLeftWidth) - parseInt(n2.borderRightWidth), i2 = B(t2, 0, e2), r2 = B(t2, 1, e2), a2 = i2 && R(i2), l2 = r2 && R(r2), s2 = a2 && parseInt(a2.marginLeft) + parseInt(a2.marginRight) + X(i2).width, t2 = l2 && parseInt(l2.marginLeft) + parseInt(l2.marginRight) + X(r2).width;
          if ("flex" === n2.display) return "column" === n2.flexDirection || "column-reverse" === n2.flexDirection ? "vertical" : "horizontal";
          if ("grid" === n2.display) return n2.gridTemplateColumns.split(" ").length <= 1 ? "vertical" : "horizontal";
          if (i2 && a2.float && "none" !== a2.float) {
            e2 = "left" === a2.float ? "left" : "right";
            return !r2 || "both" !== l2.clear && l2.clear !== e2 ? "horizontal" : "vertical";
          }
          return i2 && ("block" === a2.display || "flex" === a2.display || "table" === a2.display || "grid" === a2.display || o2 <= s2 && "none" === n2[Nt] || r2 && "none" === n2[Nt] && o2 < s2 + t2) ? "vertical" : "horizontal";
        }, Rt = function(t2) {
          function l2(r2, a2) {
            return function(t3, e3, n3, o2) {
              var i2 = t3.options.group.name && e3.options.group.name && t3.options.group.name === e3.options.group.name;
              if (null == r2 && (a2 || i2)) return true;
              if (null == r2 || false === r2) return false;
              if (a2 && "clone" === r2) return r2;
              if ("function" == typeof r2) return l2(r2(t3, e3, n3, o2), a2)(t3, e3, n3, o2);
              e3 = (a2 ? t3 : e3).options.group.name;
              return true === r2 || "string" == typeof r2 && r2 === e3 || r2.join && -1 < r2.indexOf(e3);
            };
          }
          var e2 = {}, n2 = t2.group;
          n2 && "object" == o(n2) || (n2 = { name: n2 }), e2.name = n2.name, e2.checkPull = l2(n2.pull, true), e2.checkPut = l2(n2.put), e2.revertClone = n2.revertClone, t2.group = e2;
        }, Xt = function() {
          !Pt && Q && R(Q, "display", "none");
        }, Yt = function() {
          !Pt && Q && R(Q, "display", "");
        };
        Mt && !n && document.addEventListener("click", function(t2) {
          if (Et) return t2.preventDefault(), t2.stopPropagation && t2.stopPropagation(), t2.stopImmediatePropagation && t2.stopImmediatePropagation(), Et = false;
        }, true);
        function Bt(t2) {
          if (Z) {
            t2 = t2.touches ? t2.touches[0] : t2;
            var e2 = (i2 = t2.clientX, r2 = t2.clientY, St.some(function(t3) {
              var e3 = t3[K].options.emptyInsertThreshold;
              if (e3 && !F(t3)) {
                var n3 = X(t3), o3 = i2 >= n3.left - e3 && i2 <= n3.right + e3, e3 = r2 >= n3.top - e3 && r2 <= n3.bottom + e3;
                return o3 && e3 ? a2 = t3 : void 0;
              }
            }), a2);
            if (e2) {
              var n2, o2 = {};
              for (n2 in t2) t2.hasOwnProperty(n2) && (o2[n2] = t2[n2]);
              o2.target = o2.rootEl = e2, o2.preventDefault = void 0, o2.stopPropagation = void 0, e2[K]._onDragOver(o2);
            }
          }
          var i2, r2, a2;
        }
        function Ft(t2) {
          Z && Z.parentNode[K]._isOutsideThisEl(t2.target);
        }
        function jt(t2, e2) {
          if (!t2 || !t2.nodeType || 1 !== t2.nodeType) throw "Sortable: `el` must be an HTMLElement, not ".concat({}.toString.call(t2));
          this.el = t2, this.options = e2 = a({}, e2), t2[K] = this;
          var n2, o2, i2 = { group: null, sort: true, disabled: false, store: null, handle: null, draggable: /^[uo]l$/i.test(t2.nodeName) ? ">li" : ">*", swapThreshold: 1, invertSwap: false, invertedSwapThreshold: null, removeCloneOnHide: true, direction: function() {
            return kt(t2, this.options);
          }, ghostClass: "sortable-ghost", chosenClass: "sortable-chosen", dragClass: "sortable-drag", ignore: "a, img", filter: null, preventOnFilter: true, animation: 0, easing: null, setData: function(t3, e3) {
            t3.setData("Text", e3.textContent);
          }, dropBubble: false, dragoverBubble: false, dataIdAttr: "data-id", delay: 0, delayOnTouchOnly: false, touchStartThreshold: (Number.parseInt ? Number : window).parseInt(window.devicePixelRatio, 10) || 1, forceFallback: false, fallbackClass: "sortable-fallback", fallbackOnBody: false, fallbackTolerance: 0, fallbackOffset: { x: 0, y: 0 }, supportPointer: false !== jt.supportPointer && "PointerEvent" in window && (!u || c), emptyInsertThreshold: 5 };
          for (n2 in z.initializePlugins(this, t2, i2), i2) n2 in e2 || (e2[n2] = i2[n2]);
          for (o2 in Rt(e2), this) "_" === o2.charAt(0) && "function" == typeof this[o2] && (this[o2] = this[o2].bind(this));
          this.nativeDraggable = !e2.forceFallback && It, this.nativeDraggable && (this.options.touchStartThreshold = 1), e2.supportPointer ? h(t2, "pointerdown", this._onTapStart) : (h(t2, "mousedown", this._onTapStart), h(t2, "touchstart", this._onTapStart)), this.nativeDraggable && (h(t2, "dragover", this), h(t2, "dragenter", this)), St.push(this.el), e2.store && e2.store.get && this.sort(e2.store.get(this) || []), a(this, A());
        }
        function Ht(t2, e2, n2, o2, i2, r2, a2, l2) {
          var s2, c2, u2 = t2[K], d2 = u2.options.onMove;
          return !window.CustomEvent || y || w ? (s2 = document.createEvent("Event")).initEvent("move", true, true) : s2 = new CustomEvent("move", { bubbles: true, cancelable: true }), s2.to = e2, s2.from = t2, s2.dragged = n2, s2.draggedRect = o2, s2.related = i2 || e2, s2.relatedRect = r2 || X(e2), s2.willInsertAfter = l2, s2.originalEvent = a2, t2.dispatchEvent(s2), c2 = d2 ? d2.call(u2, s2, a2) : c2;
        }
        function Lt(t2) {
          t2.draggable = false;
        }
        function Kt() {
          xt = false;
        }
        function Wt(t2) {
          return setTimeout(t2, 0);
        }
        function zt(t2) {
          return clearTimeout(t2);
        }
        jt.prototype = { constructor: jt, _isOutsideThisEl: function(t2) {
          this.el.contains(t2) || t2 === this.el || (vt = null);
        }, _getDirection: function(t2, e2) {
          return "function" == typeof this.options.direction ? this.options.direction.call(this, t2, e2, Z) : this.options.direction;
        }, _onTapStart: function(e2) {
          if (e2.cancelable) {
            var n2 = this, o2 = this.el, t2 = this.options, i2 = t2.preventOnFilter, r2 = e2.type, a2 = e2.touches && e2.touches[0] || e2.pointerType && "touch" === e2.pointerType && e2, l2 = (a2 || e2).target, s2 = e2.target.shadowRoot && (e2.path && e2.path[0] || e2.composedPath && e2.composedPath()[0]) || l2, c2 = t2.filter;
            if (!function(t3) {
              Ot.length = 0;
              var e3 = t3.getElementsByTagName("input"), n3 = e3.length;
              for (; n3--; ) {
                var o3 = e3[n3];
                o3.checked && Ot.push(o3);
              }
            }(o2), !Z && !(/mousedown|pointerdown/.test(r2) && 0 !== e2.button || t2.disabled) && !s2.isContentEditable && (this.nativeDraggable || !u || !l2 || "SELECT" !== l2.tagName.toUpperCase()) && !((l2 = P(l2, t2.draggable, o2, false)) && l2.animated || et === l2)) {
              if (it = j(l2), at = j(l2, t2.draggable), "function" == typeof c2) {
                if (c2.call(this, e2, l2, this)) return V({ sortable: n2, rootEl: s2, name: "filter", targetEl: l2, toEl: o2, fromEl: o2 }), U("filter", n2, { evt: e2 }), void (i2 && e2.preventDefault());
              } else if (c2 = c2 && c2.split(",").some(function(t3) {
                if (t3 = P(s2, t3.trim(), o2, false)) return V({ sortable: n2, rootEl: t3, name: "filter", targetEl: l2, fromEl: o2, toEl: o2 }), U("filter", n2, { evt: e2 }), true;
              })) return void (i2 && e2.preventDefault());
              t2.handle && !P(s2, t2.handle, o2, false) || this._prepareDragStart(e2, a2, l2);
            }
          }
        }, _prepareDragStart: function(t2, e2, n2) {
          var o2, i2 = this, r2 = i2.el, a2 = i2.options, l2 = r2.ownerDocument;
          n2 && !Z && n2.parentNode === r2 && (o2 = X(n2), J = r2, $ = (Z = n2).parentNode, tt = Z.nextSibling, et = n2, st = a2.group, ut = { target: jt.dragged = Z, clientX: (e2 || t2).clientX, clientY: (e2 || t2).clientY }, ft = ut.clientX - o2.left, gt = ut.clientY - o2.top, this._lastX = (e2 || t2).clientX, this._lastY = (e2 || t2).clientY, Z.style["will-change"] = "all", o2 = function() {
            U("delayEnded", i2, { evt: t2 }), jt.eventCanceled ? i2._onDrop() : (i2._disableDelayedDragEvents(), !s && i2.nativeDraggable && (Z.draggable = true), i2._triggerDragStart(t2, e2), V({ sortable: i2, name: "choose", originalEvent: t2 }), k(Z, a2.chosenClass, true));
          }, a2.ignore.split(",").forEach(function(t3) {
            D(Z, t3.trim(), Lt);
          }), h(l2, "dragover", Bt), h(l2, "mousemove", Bt), h(l2, "touchmove", Bt), a2.supportPointer ? (h(l2, "pointerup", i2._onDrop), this.nativeDraggable || h(l2, "pointercancel", i2._onDrop)) : (h(l2, "mouseup", i2._onDrop), h(l2, "touchend", i2._onDrop), h(l2, "touchcancel", i2._onDrop)), s && this.nativeDraggable && (this.options.touchStartThreshold = 4, Z.draggable = true), U("delayStart", this, { evt: t2 }), !a2.delay || a2.delayOnTouchOnly && !e2 || this.nativeDraggable && (w || y) ? o2() : jt.eventCanceled ? this._onDrop() : (a2.supportPointer ? (h(l2, "pointerup", i2._disableDelayedDrag), h(l2, "pointercancel", i2._disableDelayedDrag)) : (h(l2, "mouseup", i2._disableDelayedDrag), h(l2, "touchend", i2._disableDelayedDrag), h(l2, "touchcancel", i2._disableDelayedDrag)), h(l2, "mousemove", i2._delayedDragTouchMoveHandler), h(l2, "touchmove", i2._delayedDragTouchMoveHandler), a2.supportPointer && h(l2, "pointermove", i2._delayedDragTouchMoveHandler), i2._dragStartTimer = setTimeout(o2, a2.delay)));
        }, _delayedDragTouchMoveHandler: function(t2) {
          t2 = t2.touches ? t2.touches[0] : t2;
          Math.max(Math.abs(t2.clientX - this._lastX), Math.abs(t2.clientY - this._lastY)) >= Math.floor(this.options.touchStartThreshold / (this.nativeDraggable && window.devicePixelRatio || 1)) && this._disableDelayedDrag();
        }, _disableDelayedDrag: function() {
          Z && Lt(Z), clearTimeout(this._dragStartTimer), this._disableDelayedDragEvents();
        }, _disableDelayedDragEvents: function() {
          var t2 = this.el.ownerDocument;
          p(t2, "mouseup", this._disableDelayedDrag), p(t2, "touchend", this._disableDelayedDrag), p(t2, "touchcancel", this._disableDelayedDrag), p(t2, "pointerup", this._disableDelayedDrag), p(t2, "pointercancel", this._disableDelayedDrag), p(t2, "mousemove", this._delayedDragTouchMoveHandler), p(t2, "touchmove", this._delayedDragTouchMoveHandler), p(t2, "pointermove", this._delayedDragTouchMoveHandler);
        }, _triggerDragStart: function(t2, e2) {
          e2 = e2 || "touch" == t2.pointerType && t2, !this.nativeDraggable || e2 ? this.options.supportPointer ? h(document, "pointermove", this._onTouchMove) : h(document, e2 ? "touchmove" : "mousemove", this._onTouchMove) : (h(Z, "dragend", this), h(J, "dragstart", this._onDragStart));
          try {
            document.selection ? Wt(function() {
              document.selection.empty();
            }) : window.getSelection().removeAllRanges();
          } catch (t3) {
          }
        }, _dragStarted: function(t2, e2) {
          var n2;
          Dt = false, J && Z ? (U("dragStarted", this, { evt: e2 }), this.nativeDraggable && h(document, "dragover", Ft), n2 = this.options, t2 || k(Z, n2.dragClass, false), k(Z, n2.ghostClass, true), jt.active = this, t2 && this._appendGhost(), V({ sortable: this, name: "start", originalEvent: e2 })) : this._nulling();
        }, _emulateDragOver: function() {
          if (dt) {
            this._lastX = dt.clientX, this._lastY = dt.clientY, Xt();
            for (var t2 = document.elementFromPoint(dt.clientX, dt.clientY), e2 = t2; t2 && t2.shadowRoot && (t2 = t2.shadowRoot.elementFromPoint(dt.clientX, dt.clientY)) !== e2; ) e2 = t2;
            if (Z.parentNode[K]._isOutsideThisEl(t2), e2) do {
              if (e2[K]) {
                if (e2[K]._onDragOver({ clientX: dt.clientX, clientY: dt.clientY, target: t2, rootEl: e2 }) && !this.options.dragoverBubble) break;
              }
            } while (e2 = g(t2 = e2));
            Yt();
          }
        }, _onTouchMove: function(t2) {
          if (ut) {
            var e2 = this.options, n2 = e2.fallbackTolerance, o2 = e2.fallbackOffset, i2 = t2.touches ? t2.touches[0] : t2, r2 = Q && b(Q, true), a2 = Q && r2 && r2.a, l2 = Q && r2 && r2.d, e2 = At && wt && E(wt), a2 = (i2.clientX - ut.clientX + o2.x) / (a2 || 1) + (e2 ? e2[0] - Tt[0] : 0) / (a2 || 1), l2 = (i2.clientY - ut.clientY + o2.y) / (l2 || 1) + (e2 ? e2[1] - Tt[1] : 0) / (l2 || 1);
            if (!jt.active && !Dt) {
              if (n2 && Math.max(Math.abs(i2.clientX - this._lastX), Math.abs(i2.clientY - this._lastY)) < n2) return;
              this._onDragStart(t2, true);
            }
            Q && (r2 ? (r2.e += a2 - (ht || 0), r2.f += l2 - (pt || 0)) : r2 = { a: 1, b: 0, c: 0, d: 1, e: a2, f: l2 }, r2 = "matrix(".concat(r2.a, ",").concat(r2.b, ",").concat(r2.c, ",").concat(r2.d, ",").concat(r2.e, ",").concat(r2.f, ")"), R(Q, "webkitTransform", r2), R(Q, "mozTransform", r2), R(Q, "msTransform", r2), R(Q, "transform", r2), ht = a2, pt = l2, dt = i2), t2.cancelable && t2.preventDefault();
          }
        }, _appendGhost: function() {
          if (!Q) {
            var t2 = this.options.fallbackOnBody ? document.body : J, e2 = X(Z, true, At, true, t2), n2 = this.options;
            if (At) {
              for (wt = t2; "static" === R(wt, "position") && "none" === R(wt, "transform") && wt !== document; ) wt = wt.parentNode;
              wt !== document.body && wt !== document.documentElement ? (wt === document && (wt = O()), e2.top += wt.scrollTop, e2.left += wt.scrollLeft) : wt = O(), Tt = E(wt);
            }
            k(Q = Z.cloneNode(true), n2.ghostClass, false), k(Q, n2.fallbackClass, true), k(Q, n2.dragClass, true), R(Q, "transition", ""), R(Q, "transform", ""), R(Q, "box-sizing", "border-box"), R(Q, "margin", 0), R(Q, "top", e2.top), R(Q, "left", e2.left), R(Q, "width", e2.width), R(Q, "height", e2.height), R(Q, "opacity", "0.8"), R(Q, "position", At ? "absolute" : "fixed"), R(Q, "zIndex", "100000"), R(Q, "pointerEvents", "none"), jt.ghost = Q, t2.appendChild(Q), R(Q, "transform-origin", ft / parseInt(Q.style.width) * 100 + "% " + gt / parseInt(Q.style.height) * 100 + "%");
          }
        }, _onDragStart: function(t2, e2) {
          var n2 = this, o2 = t2.dataTransfer, i2 = n2.options;
          U("dragStart", this, { evt: t2 }), jt.eventCanceled ? this._onDrop() : (U("setupClone", this), jt.eventCanceled || ((nt = C(Z)).removeAttribute("id"), nt.draggable = false, nt.style["will-change"] = "", this._hideClone(), k(nt, this.options.chosenClass, false), jt.clone = nt), n2.cloneId = Wt(function() {
            U("clone", n2), jt.eventCanceled || (n2.options.removeCloneOnHide || J.insertBefore(nt, Z), n2._hideClone(), V({ sortable: n2, name: "clone" }));
          }), e2 || k(Z, i2.dragClass, true), e2 ? (Et = true, n2._loopId = setInterval(n2._emulateDragOver, 50)) : (p(document, "mouseup", n2._onDrop), p(document, "touchend", n2._onDrop), p(document, "touchcancel", n2._onDrop), o2 && (o2.effectAllowed = "move", i2.setData && i2.setData.call(n2, o2, Z)), h(document, "drop", n2), R(Z, "transform", "translateZ(0)")), Dt = true, n2._dragStartId = Wt(n2._dragStarted.bind(n2, e2, t2)), h(document, "selectstart", n2), mt = true, window.getSelection().removeAllRanges(), u && R(document.body, "user-select", "none"));
        }, _onDragOver: function(n2) {
          var o2, i2, r2, t2, e2, a2 = this.el, l2 = n2.target, s2 = this.options, c2 = s2.group, u2 = jt.active, d2 = st === c2, h2 = s2.sort, p2 = ct || u2, f2 = this, g2 = false;
          if (!xt) {
            if (void 0 !== n2.preventDefault && n2.cancelable && n2.preventDefault(), l2 = P(l2, s2.draggable, a2, true), O2("dragOver"), jt.eventCanceled) return g2;
            if (Z.contains(n2.target) || l2.animated && l2.animatingX && l2.animatingY || f2._ignoreWhileAnimating === l2) return A2(false);
            if (Et = false, u2 && !s2.disabled && (d2 ? h2 || (i2 = $ !== J) : ct === this || (this.lastPutMode = st.checkPull(this, u2, Z, n2)) && c2.checkPut(this, u2, Z, n2))) {
              if (r2 = "vertical" === this._getDirection(n2, l2), o2 = X(Z), O2("dragOverValid"), jt.eventCanceled) return g2;
              if (i2) return $ = J, M2(), this._hideClone(), O2("revert"), jt.eventCanceled || (tt ? J.insertBefore(Z, tt) : J.appendChild(Z)), A2(true);
              var m2 = F(a2, s2.draggable);
              if (m2 && (S2 = n2, c2 = r2, x2 = X(F((E2 = this).el, E2.options.draggable)), E2 = L(E2.el, E2.options, Q), !(c2 ? S2.clientX > E2.right + 10 || S2.clientY > x2.bottom && S2.clientX > x2.left : S2.clientY > E2.bottom + 10 || S2.clientX > x2.right && S2.clientY > x2.top) || m2.animated)) {
                if (m2 && (t2 = n2, e2 = r2, C2 = X(B((_2 = this).el, 0, _2.options, true)), _2 = L(_2.el, _2.options, Q), e2 ? t2.clientX < _2.left - 10 || t2.clientY < C2.top && t2.clientX < C2.right : t2.clientY < _2.top - 10 || t2.clientY < C2.bottom && t2.clientX < C2.left)) {
                  var v2 = B(a2, 0, s2, true);
                  if (v2 === Z) return A2(false);
                  if (D2 = X(l2 = v2), false !== Ht(J, a2, Z, o2, l2, D2, n2, false)) return M2(), a2.insertBefore(Z, v2), $ = a2, N2(), A2(true);
                } else if (l2.parentNode === a2) {
                  var b2, y2, w2, D2 = X(l2), E2 = Z.parentNode !== a2, S2 = (S2 = Z.animated && Z.toRect || o2, x2 = l2.animated && l2.toRect || D2, _2 = (e2 = r2) ? S2.left : S2.top, t2 = e2 ? S2.right : S2.bottom, C2 = e2 ? S2.width : S2.height, v2 = e2 ? x2.left : x2.top, S2 = e2 ? x2.right : x2.bottom, x2 = e2 ? x2.width : x2.height, !(_2 === v2 || t2 === S2 || _2 + C2 / 2 === v2 + x2 / 2)), _2 = r2 ? "top" : "left", C2 = Y(l2, "top", "top") || Y(Z, "top", "top"), v2 = C2 ? C2.scrollTop : void 0;
                  if (vt !== l2 && (y2 = D2[_2], _t = false, Ct = !S2 && s2.invertSwap || E2), 0 !== (b2 = function(t3, e3, n3, o3, i3, r3, a3, l3) {
                    var s3 = o3 ? t3.clientY : t3.clientX, c3 = o3 ? n3.height : n3.width, t3 = o3 ? n3.top : n3.left, o3 = o3 ? n3.bottom : n3.right, n3 = false;
                    if (!a3) {
                      if (l3 && yt < c3 * i3) {
                        if (_t = !_t && (1 === bt ? t3 + c3 * r3 / 2 < s3 : s3 < o3 - c3 * r3 / 2) ? true : _t) n3 = true;
                        else if (1 === bt ? s3 < t3 + yt : o3 - yt < s3) return -bt;
                      } else if (t3 + c3 * (1 - i3) / 2 < s3 && s3 < o3 - c3 * (1 - i3) / 2) return function(t4) {
                        return j(Z) < j(t4) ? 1 : -1;
                      }(e3);
                    }
                    if ((n3 = n3 || a3) && (s3 < t3 + c3 * r3 / 2 || o3 - c3 * r3 / 2 < s3)) return t3 + c3 / 2 < s3 ? 1 : -1;
                    return 0;
                  }(n2, l2, D2, r2, S2 ? 1 : s2.swapThreshold, null == s2.invertedSwapThreshold ? s2.swapThreshold : s2.invertedSwapThreshold, Ct, vt === l2))) for (var T2 = j(Z); (w2 = $.children[T2 -= b2]) && ("none" === R(w2, "display") || w2 === Q); ) ;
                  if (0 === b2 || w2 === l2) return A2(false);
                  bt = b2;
                  var x2 = (vt = l2).nextElementSibling, E2 = false, S2 = Ht(J, a2, Z, o2, l2, D2, n2, E2 = 1 === b2);
                  if (false !== S2) return 1 !== S2 && -1 !== S2 || (E2 = 1 === S2), xt = true, setTimeout(Kt, 30), M2(), E2 && !x2 ? a2.appendChild(Z) : l2.parentNode.insertBefore(Z, E2 ? x2 : l2), C2 && H(C2, 0, v2 - C2.scrollTop), $ = Z.parentNode, void 0 === y2 || Ct || (yt = Math.abs(y2 - X(l2)[_2])), N2(), A2(true);
                }
              } else {
                if (m2 === Z) return A2(false);
                if ((l2 = m2 && a2 === n2.target ? m2 : l2) && (D2 = X(l2)), false !== Ht(J, a2, Z, o2, l2, D2, n2, !!l2)) return M2(), m2 && m2.nextSibling ? a2.insertBefore(Z, m2.nextSibling) : a2.appendChild(Z), $ = a2, N2(), A2(true);
              }
              if (a2.contains(Z)) return A2(false);
            }
            return false;
          }
          function O2(t3, e3) {
            U(t3, f2, I({ evt: n2, isOwner: d2, axis: r2 ? "vertical" : "horizontal", revert: i2, dragRect: o2, targetRect: D2, canSort: h2, fromSortable: p2, target: l2, completed: A2, onMove: function(t4, e4) {
              return Ht(J, a2, Z, o2, t4, X(t4), n2, e4);
            }, changed: N2 }, e3));
          }
          function M2() {
            O2("dragOverAnimationCapture"), f2.captureAnimationState(), f2 !== p2 && p2.captureAnimationState();
          }
          function A2(t3) {
            return O2("dragOverCompleted", { insertion: t3 }), t3 && (d2 ? u2._hideClone() : u2._showClone(f2), f2 !== p2 && (k(Z, (ct || u2).options.ghostClass, false), k(Z, s2.ghostClass, true)), ct !== f2 && f2 !== jt.active ? ct = f2 : f2 === jt.active && ct && (ct = null), p2 === f2 && (f2._ignoreWhileAnimating = l2), f2.animateAll(function() {
              O2("dragOverAnimationComplete"), f2._ignoreWhileAnimating = null;
            }), f2 !== p2 && (p2.animateAll(), p2._ignoreWhileAnimating = null)), (l2 === Z && !Z.animated || l2 === a2 && !l2.animated) && (vt = null), s2.dragoverBubble || n2.rootEl || l2 === document || (Z.parentNode[K]._isOutsideThisEl(n2.target), t3 || Bt(n2)), !s2.dragoverBubble && n2.stopPropagation && n2.stopPropagation(), g2 = true;
          }
          function N2() {
            rt = j(Z), lt = j(Z, s2.draggable), V({ sortable: f2, name: "change", toEl: a2, newIndex: rt, newDraggableIndex: lt, originalEvent: n2 });
          }
        }, _ignoreWhileAnimating: null, _offMoveEvents: function() {
          p(document, "mousemove", this._onTouchMove), p(document, "touchmove", this._onTouchMove), p(document, "pointermove", this._onTouchMove), p(document, "dragover", Bt), p(document, "mousemove", Bt), p(document, "touchmove", Bt);
        }, _offUpEvents: function() {
          var t2 = this.el.ownerDocument;
          p(t2, "mouseup", this._onDrop), p(t2, "touchend", this._onDrop), p(t2, "pointerup", this._onDrop), p(t2, "pointercancel", this._onDrop), p(t2, "touchcancel", this._onDrop), p(document, "selectstart", this);
        }, _onDrop: function(t2) {
          var e2 = this.el, n2 = this.options;
          rt = j(Z), lt = j(Z, n2.draggable), U("drop", this, { evt: t2 }), $ = Z && Z.parentNode, rt = j(Z), lt = j(Z, n2.draggable), jt.eventCanceled || (_t = Ct = Dt = false, clearInterval(this._loopId), clearTimeout(this._dragStartTimer), zt(this.cloneId), zt(this._dragStartId), this.nativeDraggable && (p(document, "drop", this), p(e2, "dragstart", this._onDragStart)), this._offMoveEvents(), this._offUpEvents(), u && R(document.body, "user-select", ""), R(Z, "transform", ""), t2 && (mt && (t2.cancelable && t2.preventDefault(), n2.dropBubble || t2.stopPropagation()), Q && Q.parentNode && Q.parentNode.removeChild(Q), (J === $ || ct && "clone" !== ct.lastPutMode) && nt && nt.parentNode && nt.parentNode.removeChild(nt), Z && (this.nativeDraggable && p(Z, "dragend", this), Lt(Z), Z.style["will-change"] = "", mt && !Dt && k(Z, (ct || this).options.ghostClass, false), k(Z, this.options.chosenClass, false), V({ sortable: this, name: "unchoose", toEl: $, newIndex: null, newDraggableIndex: null, originalEvent: t2 }), J !== $ ? (0 <= rt && (V({ rootEl: $, name: "add", toEl: $, fromEl: J, originalEvent: t2 }), V({ sortable: this, name: "remove", toEl: $, originalEvent: t2 }), V({ rootEl: $, name: "sort", toEl: $, fromEl: J, originalEvent: t2 }), V({ sortable: this, name: "sort", toEl: $, originalEvent: t2 })), ct && ct.save()) : rt !== it && 0 <= rt && (V({ sortable: this, name: "update", toEl: $, originalEvent: t2 }), V({ sortable: this, name: "sort", toEl: $, originalEvent: t2 })), jt.active && (null != rt && -1 !== rt || (rt = it, lt = at), V({ sortable: this, name: "end", toEl: $, originalEvent: t2 }), this.save())))), this._nulling();
        }, _nulling: function() {
          U("nulling", this), J = Z = $ = Q = tt = nt = et = ot = ut = dt = mt = rt = lt = it = at = vt = bt = ct = st = jt.dragged = jt.ghost = jt.clone = jt.active = null, Ot.forEach(function(t2) {
            t2.checked = true;
          }), Ot.length = ht = pt = 0;
        }, handleEvent: function(t2) {
          switch (t2.type) {
            case "drop":
            case "dragend":
              this._onDrop(t2);
              break;
            case "dragenter":
            case "dragover":
              Z && (this._onDragOver(t2), function(t3) {
                t3.dataTransfer && (t3.dataTransfer.dropEffect = "move");
                t3.cancelable && t3.preventDefault();
              }(t2));
              break;
            case "selectstart":
              t2.preventDefault();
          }
        }, toArray: function() {
          for (var t2, e2 = [], n2 = this.el.children, o2 = 0, i2 = n2.length, r2 = this.options; o2 < i2; o2++) P(t2 = n2[o2], r2.draggable, this.el, false) && e2.push(t2.getAttribute(r2.dataIdAttr) || function(t3) {
            var e3 = t3.tagName + t3.className + t3.src + t3.href + t3.textContent, n3 = e3.length, o3 = 0;
            for (; n3--; ) o3 += e3.charCodeAt(n3);
            return o3.toString(36);
          }(t2));
          return e2;
        }, sort: function(t2, e2) {
          var n2 = {}, o2 = this.el;
          this.toArray().forEach(function(t3, e3) {
            e3 = o2.children[e3];
            P(e3, this.options.draggable, o2, false) && (n2[t3] = e3);
          }, this), e2 && this.captureAnimationState(), t2.forEach(function(t3) {
            n2[t3] && (o2.removeChild(n2[t3]), o2.appendChild(n2[t3]));
          }), e2 && this.animateAll();
        }, save: function() {
          var t2 = this.options.store;
          t2 && t2.set && t2.set(this);
        }, closest: function(t2, e2) {
          return P(t2, e2 || this.options.draggable, this.el, false);
        }, option: function(t2, e2) {
          var n2 = this.options;
          if (void 0 === e2) return n2[t2];
          var o2 = z.modifyOption(this, t2, e2);
          n2[t2] = void 0 !== o2 ? o2 : e2, "group" === t2 && Rt(n2);
        }, destroy: function() {
          U("destroy", this);
          var t2 = this.el;
          t2[K] = null, p(t2, "mousedown", this._onTapStart), p(t2, "touchstart", this._onTapStart), p(t2, "pointerdown", this._onTapStart), this.nativeDraggable && (p(t2, "dragover", this), p(t2, "dragenter", this)), Array.prototype.forEach.call(t2.querySelectorAll("[draggable]"), function(t3) {
            t3.removeAttribute("draggable");
          }), this._onDrop(), this._disableDelayedDragEvents(), St.splice(St.indexOf(this.el), 1), this.el = t2 = null;
        }, _hideClone: function() {
          ot || (U("hideClone", this), jt.eventCanceled || (R(nt, "display", "none"), this.options.removeCloneOnHide && nt.parentNode && nt.parentNode.removeChild(nt), ot = true));
        }, _showClone: function(t2) {
          "clone" === t2.lastPutMode ? ot && (U("showClone", this), jt.eventCanceled || (Z.parentNode != J || this.options.group.revertClone ? tt ? J.insertBefore(nt, tt) : J.appendChild(nt) : J.insertBefore(nt, Z), this.options.group.revertClone && this.animate(Z, nt), R(nt, "display", ""), ot = false)) : this._hideClone();
        } }, Mt && h(document, "touchmove", function(t2) {
          (jt.active || Dt) && t2.cancelable && t2.preventDefault();
        }), jt.utils = { on: h, off: p, css: R, find: D, is: function(t2, e2) {
          return !!P(t2, e2, t2, false);
        }, extend: function(t2, e2) {
          if (t2 && e2) for (var n2 in e2) e2.hasOwnProperty(n2) && (t2[n2] = e2[n2]);
          return t2;
        }, throttle: _, closest: P, toggleClass: k, clone: C, index: j, nextTick: Wt, cancelNextTick: zt, detectDirection: kt, getChild: B, expando: K }, jt.get = function(t2) {
          return t2[K];
        }, jt.mount = function() {
          for (var t2 = arguments.length, e2 = new Array(t2), n2 = 0; n2 < t2; n2++) e2[n2] = arguments[n2];
          (e2 = e2[0].constructor === Array ? e2[0] : e2).forEach(function(t3) {
            if (!t3.prototype || !t3.prototype.constructor) throw "Sortable: Mounted plugin must be a constructor function, not ".concat({}.toString.call(t3));
            t3.utils && (jt.utils = I(I({}, jt.utils), t3.utils)), z.mount(t3);
          });
        }, jt.create = function(t2, e2) {
          return new jt(t2, e2);
        };
        var Gt, Ut, qt, Vt, Zt, $t, Qt = [], Jt = !(jt.version = "1.15.6");
        function te() {
          Qt.forEach(function(t2) {
            clearInterval(t2.pid);
          }), Qt = [];
        }
        function ee() {
          clearInterval($t);
        }
        var ne, oe = _(function(n2, t2, e2, o2) {
          if (t2.scroll) {
            var i2, r2 = (n2.touches ? n2.touches[0] : n2).clientX, a2 = (n2.touches ? n2.touches[0] : n2).clientY, l2 = t2.scrollSensitivity, s2 = t2.scrollSpeed, c2 = O(), u2 = false;
            Ut !== e2 && (Ut = e2, te(), Gt = t2.scroll, i2 = t2.scrollFn, true === Gt && (Gt = M(e2, true)));
            var d2 = 0, h2 = Gt;
            do {
              var p2 = h2, f2 = X(p2), g2 = f2.top, m2 = f2.bottom, v2 = f2.left, b2 = f2.right, y2 = f2.width, w2 = f2.height, D2 = void 0, E2 = void 0, S2 = p2.scrollWidth, _2 = p2.scrollHeight, C2 = R(p2), T2 = p2.scrollLeft, f2 = p2.scrollTop, E2 = p2 === c2 ? (D2 = y2 < S2 && ("auto" === C2.overflowX || "scroll" === C2.overflowX || "visible" === C2.overflowX), w2 < _2 && ("auto" === C2.overflowY || "scroll" === C2.overflowY || "visible" === C2.overflowY)) : (D2 = y2 < S2 && ("auto" === C2.overflowX || "scroll" === C2.overflowX), w2 < _2 && ("auto" === C2.overflowY || "scroll" === C2.overflowY)), T2 = D2 && (Math.abs(b2 - r2) <= l2 && T2 + y2 < S2) - (Math.abs(v2 - r2) <= l2 && !!T2), f2 = E2 && (Math.abs(m2 - a2) <= l2 && f2 + w2 < _2) - (Math.abs(g2 - a2) <= l2 && !!f2);
              if (!Qt[d2]) for (var x2 = 0; x2 <= d2; x2++) Qt[x2] || (Qt[x2] = {});
              Qt[d2].vx == T2 && Qt[d2].vy == f2 && Qt[d2].el === p2 || (Qt[d2].el = p2, Qt[d2].vx = T2, Qt[d2].vy = f2, clearInterval(Qt[d2].pid), 0 == T2 && 0 == f2 || (u2 = true, Qt[d2].pid = setInterval(function() {
                o2 && 0 === this.layer && jt.active._onTouchMove(Zt);
                var t3 = Qt[this.layer].vy ? Qt[this.layer].vy * s2 : 0, e3 = Qt[this.layer].vx ? Qt[this.layer].vx * s2 : 0;
                "function" == typeof i2 && "continue" !== i2.call(jt.dragged.parentNode[K], e3, t3, n2, Zt, Qt[this.layer].el) || H(Qt[this.layer].el, e3, t3);
              }.bind({ layer: d2 }), 24))), d2++;
            } while (t2.bubbleScroll && h2 !== c2 && (h2 = M(h2, false)));
            Jt = u2;
          }
        }, 30), n = function(t2) {
          var e2 = t2.originalEvent, n2 = t2.putSortable, o2 = t2.dragEl, i2 = t2.activeSortable, r2 = t2.dispatchSortableEvent, a2 = t2.hideGhostForTarget, t2 = t2.unhideGhostForTarget;
          e2 && (i2 = n2 || i2, a2(), e2 = e2.changedTouches && e2.changedTouches.length ? e2.changedTouches[0] : e2, e2 = document.elementFromPoint(e2.clientX, e2.clientY), t2(), i2 && !i2.el.contains(e2) && (r2("spill"), this.onSpill({ dragEl: o2, putSortable: n2 })));
        };
        function ie() {
        }
        function re() {
        }
        ie.prototype = { startIndex: null, dragStart: function(t2) {
          t2 = t2.oldDraggableIndex;
          this.startIndex = t2;
        }, onSpill: function(t2) {
          var e2 = t2.dragEl, n2 = t2.putSortable;
          this.sortable.captureAnimationState(), n2 && n2.captureAnimationState();
          t2 = B(this.sortable.el, this.startIndex, this.options);
          t2 ? this.sortable.el.insertBefore(e2, t2) : this.sortable.el.appendChild(e2), this.sortable.animateAll(), n2 && n2.animateAll();
        }, drop: n }, a(ie, { pluginName: "revertOnSpill" }), re.prototype = { onSpill: function(t2) {
          var e2 = t2.dragEl, t2 = t2.putSortable || this.sortable;
          t2.captureAnimationState(), e2.parentNode && e2.parentNode.removeChild(e2), t2.animateAll();
        }, drop: n }, a(re, { pluginName: "removeOnSpill" });
        var ae, le, se, ce, ue, de = [], he = [], pe = false, fe = false, ge = false;
        function me(n2, o2) {
          he.forEach(function(t2, e2) {
            e2 = o2.children[t2.sortableIndex + (n2 ? Number(e2) : 0)];
            e2 ? o2.insertBefore(t2, e2) : o2.appendChild(t2);
          });
        }
        function ve() {
          de.forEach(function(t2) {
            t2 !== se && t2.parentNode && t2.parentNode.removeChild(t2);
          });
        }
        return jt.mount(new function() {
          function t2() {
            for (var t3 in this.defaults = { scroll: true, forceAutoScrollFallback: false, scrollSensitivity: 30, scrollSpeed: 10, bubbleScroll: true }, this) "_" === t3.charAt(0) && "function" == typeof this[t3] && (this[t3] = this[t3].bind(this));
          }
          return t2.prototype = { dragStarted: function(t3) {
            t3 = t3.originalEvent;
            this.sortable.nativeDraggable ? h(document, "dragover", this._handleAutoScroll) : this.options.supportPointer ? h(document, "pointermove", this._handleFallbackAutoScroll) : t3.touches ? h(document, "touchmove", this._handleFallbackAutoScroll) : h(document, "mousemove", this._handleFallbackAutoScroll);
          }, dragOverCompleted: function(t3) {
            t3 = t3.originalEvent;
            this.options.dragOverBubble || t3.rootEl || this._handleAutoScroll(t3);
          }, drop: function() {
            this.sortable.nativeDraggable ? p(document, "dragover", this._handleAutoScroll) : (p(document, "pointermove", this._handleFallbackAutoScroll), p(document, "touchmove", this._handleFallbackAutoScroll), p(document, "mousemove", this._handleFallbackAutoScroll)), ee(), te(), clearTimeout(m), m = void 0;
          }, nulling: function() {
            Zt = Ut = Gt = Jt = $t = qt = Vt = null, Qt.length = 0;
          }, _handleFallbackAutoScroll: function(t3) {
            this._handleAutoScroll(t3, true);
          }, _handleAutoScroll: function(e2, n2) {
            var o2, i2 = this, r2 = (e2.touches ? e2.touches[0] : e2).clientX, a2 = (e2.touches ? e2.touches[0] : e2).clientY, t3 = document.elementFromPoint(r2, a2);
            Zt = e2, n2 || this.options.forceAutoScrollFallback || w || y || u ? (oe(e2, this.options, t3, n2), o2 = M(t3, true), !Jt || $t && r2 === qt && a2 === Vt || ($t && ee(), $t = setInterval(function() {
              var t4 = M(document.elementFromPoint(r2, a2), true);
              t4 !== o2 && (o2 = t4, te()), oe(e2, i2.options, t4, n2);
            }, 10), qt = r2, Vt = a2)) : this.options.bubbleScroll && M(t3, true) !== O() ? oe(e2, this.options, M(t3, false), false) : te();
          } }, a(t2, { pluginName: "scroll", initializeByDefault: true });
        }()), jt.mount(re, ie), jt.mount(new function() {
          function t2() {
            this.defaults = { swapClass: "sortable-swap-highlight" };
          }
          return t2.prototype = { dragStart: function(t3) {
            t3 = t3.dragEl;
            ne = t3;
          }, dragOverValid: function(t3) {
            var e2 = t3.completed, n2 = t3.target, o2 = t3.onMove, i2 = t3.activeSortable, r2 = t3.changed, a2 = t3.cancel;
            i2.options.swap && (t3 = this.sortable.el, i2 = this.options, n2 && n2 !== t3 && (t3 = ne, ne = false !== o2(n2) ? (k(n2, i2.swapClass, true), n2) : null, t3 && t3 !== ne && k(t3, i2.swapClass, false)), r2(), e2(true), a2());
          }, drop: function(t3) {
            var e2, n2, o2 = t3.activeSortable, i2 = t3.putSortable, r2 = t3.dragEl, a2 = i2 || this.sortable, l2 = this.options;
            ne && k(ne, l2.swapClass, false), ne && (l2.swap || i2 && i2.options.swap) && r2 !== ne && (a2.captureAnimationState(), a2 !== o2 && o2.captureAnimationState(), n2 = ne, t3 = (e2 = r2).parentNode, l2 = n2.parentNode, t3 && l2 && !t3.isEqualNode(n2) && !l2.isEqualNode(e2) && (i2 = j(e2), r2 = j(n2), t3.isEqualNode(l2) && i2 < r2 && r2++, t3.insertBefore(n2, t3.children[i2]), l2.insertBefore(e2, l2.children[r2])), a2.animateAll(), a2 !== o2 && o2.animateAll());
          }, nulling: function() {
            ne = null;
          } }, a(t2, { pluginName: "swap", eventProperties: function() {
            return { swapItem: ne };
          } });
        }()), jt.mount(new function() {
          function t2(o2) {
            for (var t3 in this) "_" === t3.charAt(0) && "function" == typeof this[t3] && (this[t3] = this[t3].bind(this));
            o2.options.avoidImplicitDeselect || (o2.options.supportPointer ? h(document, "pointerup", this._deselectMultiDrag) : (h(document, "mouseup", this._deselectMultiDrag), h(document, "touchend", this._deselectMultiDrag))), h(document, "keydown", this._checkKeyDown), h(document, "keyup", this._checkKeyUp), this.defaults = { selectedClass: "sortable-selected", multiDragKey: null, avoidImplicitDeselect: false, setData: function(t4, e2) {
              var n2 = "";
              de.length && le === o2 ? de.forEach(function(t5, e3) {
                n2 += (e3 ? ", " : "") + t5.textContent;
              }) : n2 = e2.textContent, t4.setData("Text", n2);
            } };
          }
          return t2.prototype = { multiDragKeyDown: false, isMultiDrag: false, delayStartGlobal: function(t3) {
            t3 = t3.dragEl;
            se = t3;
          }, delayEnded: function() {
            this.isMultiDrag = ~de.indexOf(se);
          }, setupClone: function(t3) {
            var e2 = t3.sortable, t3 = t3.cancel;
            if (this.isMultiDrag) {
              for (var n2 = 0; n2 < de.length; n2++) he.push(C(de[n2])), he[n2].sortableIndex = de[n2].sortableIndex, he[n2].draggable = false, he[n2].style["will-change"] = "", k(he[n2], this.options.selectedClass, false), de[n2] === se && k(he[n2], this.options.chosenClass, false);
              e2._hideClone(), t3();
            }
          }, clone: function(t3) {
            var e2 = t3.sortable, n2 = t3.rootEl, o2 = t3.dispatchSortableEvent, t3 = t3.cancel;
            this.isMultiDrag && (this.options.removeCloneOnHide || de.length && le === e2 && (me(true, n2), o2("clone"), t3()));
          }, showClone: function(t3) {
            var e2 = t3.cloneNowShown, n2 = t3.rootEl, t3 = t3.cancel;
            this.isMultiDrag && (me(false, n2), he.forEach(function(t4) {
              R(t4, "display", "");
            }), e2(), ue = false, t3());
          }, hideClone: function(t3) {
            var e2 = this, n2 = (t3.sortable, t3.cloneNowHidden), t3 = t3.cancel;
            this.isMultiDrag && (he.forEach(function(t4) {
              R(t4, "display", "none"), e2.options.removeCloneOnHide && t4.parentNode && t4.parentNode.removeChild(t4);
            }), n2(), ue = true, t3());
          }, dragStartGlobal: function(t3) {
            t3.sortable;
            !this.isMultiDrag && le && le.multiDrag._deselectMultiDrag(), de.forEach(function(t4) {
              t4.sortableIndex = j(t4);
            }), de = de.sort(function(t4, e2) {
              return t4.sortableIndex - e2.sortableIndex;
            }), ge = true;
          }, dragStarted: function(t3) {
            var e2, n2 = this, t3 = t3.sortable;
            this.isMultiDrag && (this.options.sort && (t3.captureAnimationState(), this.options.animation && (de.forEach(function(t4) {
              t4 !== se && R(t4, "position", "absolute");
            }), e2 = X(se, false, true, true), de.forEach(function(t4) {
              t4 !== se && T(t4, e2);
            }), pe = fe = true)), t3.animateAll(function() {
              pe = fe = false, n2.options.animation && de.forEach(function(t4) {
                x(t4);
              }), n2.options.sort && ve();
            }));
          }, dragOver: function(t3) {
            var e2 = t3.target, n2 = t3.completed, t3 = t3.cancel;
            fe && ~de.indexOf(e2) && (n2(false), t3());
          }, revert: function(t3) {
            var n2, o2, e2 = t3.fromSortable, i2 = t3.rootEl, r2 = t3.sortable, a2 = t3.dragRect;
            1 < de.length && (de.forEach(function(t4) {
              r2.addAnimationState({ target: t4, rect: fe ? X(t4) : a2 }), x(t4), t4.fromRect = a2, e2.removeAnimationState(t4);
            }), fe = false, n2 = !this.options.removeCloneOnHide, o2 = i2, de.forEach(function(t4, e3) {
              e3 = o2.children[t4.sortableIndex + (n2 ? Number(e3) : 0)];
              e3 ? o2.insertBefore(t4, e3) : o2.appendChild(t4);
            }));
          }, dragOverCompleted: function(t3) {
            var e2, n2 = t3.sortable, o2 = t3.isOwner, i2 = t3.insertion, r2 = t3.activeSortable, a2 = t3.parentEl, l2 = t3.putSortable, t3 = this.options;
            i2 && (o2 && r2._hideClone(), pe = false, t3.animation && 1 < de.length && (fe || !o2 && !r2.options.sort && !l2) && (e2 = X(se, false, true, true), de.forEach(function(t4) {
              t4 !== se && (T(t4, e2), a2.appendChild(t4));
            }), fe = true), o2 || (fe || ve(), 1 < de.length ? (o2 = ue, r2._showClone(n2), r2.options.animation && !ue && o2 && he.forEach(function(t4) {
              r2.addAnimationState({ target: t4, rect: ce }), t4.fromRect = ce, t4.thisAnimationDuration = null;
            })) : r2._showClone(n2)));
          }, dragOverAnimationCapture: function(t3) {
            var e2 = t3.dragRect, n2 = t3.isOwner, t3 = t3.activeSortable;
            de.forEach(function(t4) {
              t4.thisAnimationDuration = null;
            }), t3.options.animation && !n2 && t3.multiDrag.isMultiDrag && (ce = a({}, e2), e2 = b(se, true), ce.top -= e2.f, ce.left -= e2.e);
          }, dragOverAnimationComplete: function() {
            fe && (fe = false, ve());
          }, drop: function(t3) {
            var o2, i2, r2, a2, n2, e2, l2, s2 = t3.originalEvent, c2 = t3.rootEl, u2 = t3.parentEl, d2 = t3.sortable, h2 = t3.dispatchSortableEvent, p2 = t3.oldIndex, t3 = t3.putSortable, f2 = t3 || this.sortable;
            s2 && (o2 = this.options, i2 = u2.children, ge || (o2.multiDragKey && !this.multiDragKeyDown && this._deselectMultiDrag(), k(se, o2.selectedClass, !~de.indexOf(se)), ~de.indexOf(se) ? (de.splice(de.indexOf(se), 1), ae = null, G({ sortable: d2, rootEl: c2, name: "deselect", targetEl: se, originalEvent: s2 })) : (de.push(se), G({ sortable: d2, rootEl: c2, name: "select", targetEl: se, originalEvent: s2 }), s2.shiftKey && ae && d2.el.contains(ae) ? (r2 = j(ae), a2 = j(se), ~r2 && ~a2 && r2 !== a2 && function() {
              for (var e3, t4 = r2 < a2 ? (e3 = r2, a2) : (e3 = a2, r2 + 1), n3 = o2.filter; e3 < t4; e3++) ~de.indexOf(i2[e3]) || P(i2[e3], o2.draggable, u2, false) && (n3 && ("function" == typeof n3 ? n3.call(d2, s2, i2[e3], d2) : n3.split(",").some(function(t5) {
                return P(i2[e3], t5.trim(), u2, false);
              })) || (k(i2[e3], o2.selectedClass, true), de.push(i2[e3]), G({ sortable: d2, rootEl: c2, name: "select", targetEl: i2[e3], originalEvent: s2 })));
            }()) : ae = se, le = f2)), ge && this.isMultiDrag && (fe = false, (u2[K].options.sort || u2 !== c2) && 1 < de.length && (n2 = X(se), e2 = j(se, ":not(." + this.options.selectedClass + ")"), !pe && o2.animation && (se.thisAnimationDuration = null), f2.captureAnimationState(), pe || (o2.animation && (se.fromRect = n2, de.forEach(function(t4) {
              var e3;
              t4.thisAnimationDuration = null, t4 !== se && (e3 = fe ? X(t4) : n2, t4.fromRect = e3, f2.addAnimationState({ target: t4, rect: e3 }));
            })), ve(), de.forEach(function(t4) {
              i2[e2] ? u2.insertBefore(t4, i2[e2]) : u2.appendChild(t4), e2++;
            }), p2 === j(se) && (l2 = false, de.forEach(function(t4) {
              t4.sortableIndex !== j(t4) && (l2 = true);
            }), l2 && (h2("update"), h2("sort")))), de.forEach(function(t4) {
              x(t4);
            }), f2.animateAll()), le = f2), (c2 === u2 || t3 && "clone" !== t3.lastPutMode) && he.forEach(function(t4) {
              t4.parentNode && t4.parentNode.removeChild(t4);
            }));
          }, nullingGlobal: function() {
            this.isMultiDrag = ge = false, he.length = 0;
          }, destroyGlobal: function() {
            this._deselectMultiDrag(), p(document, "pointerup", this._deselectMultiDrag), p(document, "mouseup", this._deselectMultiDrag), p(document, "touchend", this._deselectMultiDrag), p(document, "keydown", this._checkKeyDown), p(document, "keyup", this._checkKeyUp);
          }, _deselectMultiDrag: function(t3) {
            if (!(void 0 !== ge && ge || le !== this.sortable || t3 && P(t3.target, this.options.draggable, this.sortable.el, false) || t3 && 0 !== t3.button)) for (; de.length; ) {
              var e2 = de[0];
              k(e2, this.options.selectedClass, false), de.shift(), G({ sortable: this.sortable, rootEl: this.sortable.el, name: "deselect", targetEl: e2, originalEvent: t3 });
            }
          }, _checkKeyDown: function(t3) {
            t3.key === this.options.multiDragKey && (this.multiDragKeyDown = true);
          }, _checkKeyUp: function(t3) {
            t3.key === this.options.multiDragKey && (this.multiDragKeyDown = false);
          } }, a(t2, { pluginName: "multiDrag", utils: { select: function(t3) {
            var e2 = t3.parentNode[K];
            e2 && e2.options.multiDrag && !~de.indexOf(t3) && (le && le !== e2 && (le.multiDrag._deselectMultiDrag(), le = e2), k(t3, e2.options.selectedClass, true), de.push(t3));
          }, deselect: function(t3) {
            var e2 = t3.parentNode[K], n2 = de.indexOf(t3);
            e2 && e2.options.multiDrag && ~n2 && (k(t3, e2.options.selectedClass, false), de.splice(n2, 1));
          } }, eventProperties: function() {
            var n2 = this, o2 = [], i2 = [];
            return de.forEach(function(t3) {
              var e2;
              o2.push({ multiDragElement: t3, index: t3.sortableIndex }), e2 = fe && t3 !== se ? -1 : fe ? j(t3, ":not(." + n2.options.selectedClass + ")") : j(t3), i2.push({ multiDragElement: t3, index: e2 });
            }), { items: r(de), clones: [].concat(he), oldIndicies: o2, newIndicies: i2 };
          }, optionListeners: { multiDragKey: function(t3) {
            return "ctrl" === (t3 = t3.toLowerCase()) ? t3 = "Control" : 1 < t3.length && (t3 = t3.charAt(0).toUpperCase() + t3.substr(1)), t3;
          } } });
        }()), jt;
      });
    }
  });

  // vendor/graphology.umd.min.js
  var require_graphology_umd_min = __commonJS({
    "vendor/graphology.umd.min.js"(exports, module) {
      !function(t, e) {
        "object" == typeof exports && "undefined" != typeof module ? module.exports = e() : "function" == typeof define && define.amd ? define(e) : (t = "undefined" != typeof globalThis ? globalThis : t || self).graphology = e();
      }(exports, function() {
        "use strict";
        function t(e2) {
          return t = "function" == typeof Symbol && "symbol" == typeof Symbol.iterator ? function(t2) {
            return typeof t2;
          } : function(t2) {
            return t2 && "function" == typeof Symbol && t2.constructor === Symbol && t2 !== Symbol.prototype ? "symbol" : typeof t2;
          }, t(e2);
        }
        function e(t2, e2) {
          t2.prototype = Object.create(e2.prototype), t2.prototype.constructor = t2, r(t2, e2);
        }
        function n(t2) {
          return n = Object.setPrototypeOf ? Object.getPrototypeOf.bind() : function(t3) {
            return t3.__proto__ || Object.getPrototypeOf(t3);
          }, n(t2);
        }
        function r(t2, e2) {
          return r = Object.setPrototypeOf ? Object.setPrototypeOf.bind() : function(t3, e3) {
            return t3.__proto__ = e3, t3;
          }, r(t2, e2);
        }
        function i() {
          if ("undefined" == typeof Reflect || !Reflect.construct) return false;
          if (Reflect.construct.sham) return false;
          if ("function" == typeof Proxy) return true;
          try {
            return Boolean.prototype.valueOf.call(Reflect.construct(Boolean, [], function() {
            })), true;
          } catch (t2) {
            return false;
          }
        }
        function o(t2, e2, n2) {
          return o = i() ? Reflect.construct.bind() : function(t3, e3, n3) {
            var i2 = [null];
            i2.push.apply(i2, e3);
            var o2 = new (Function.bind.apply(t3, i2))();
            return n3 && r(o2, n3.prototype), o2;
          }, o.apply(null, arguments);
        }
        function a(t2) {
          var e2 = "function" == typeof Map ? /* @__PURE__ */ new Map() : void 0;
          return a = function(t3) {
            if (null === t3 || (i2 = t3, -1 === Function.toString.call(i2).indexOf("[native code]"))) return t3;
            var i2;
            if ("function" != typeof t3) throw new TypeError("Super expression must either be null or a function");
            if (void 0 !== e2) {
              if (e2.has(t3)) return e2.get(t3);
              e2.set(t3, a2);
            }
            function a2() {
              return o(t3, arguments, n(this).constructor);
            }
            return a2.prototype = Object.create(t3.prototype, { constructor: { value: a2, enumerable: false, writable: true, configurable: true } }), r(a2, t3);
          }, a(t2);
        }
        function c(t2) {
          if (void 0 === t2) throw new ReferenceError("this hasn't been initialised - super() hasn't been called");
          return t2;
        }
        var u = function() {
          for (var t2 = arguments[0], e2 = 1, n2 = arguments.length; e2 < n2; e2++) if (arguments[e2]) for (var r2 in arguments[e2]) t2[r2] = arguments[e2][r2];
          return t2;
        };
        function d(t2, e2, n2, r2) {
          var i2 = t2._nodes.get(e2), o2 = null;
          return i2 ? o2 = "mixed" === r2 ? i2.out && i2.out[n2] || i2.undirected && i2.undirected[n2] : "directed" === r2 ? i2.out && i2.out[n2] : i2.undirected && i2.undirected[n2] : o2;
        }
        function s(e2) {
          return "object" === t(e2) && null !== e2;
        }
        function h(t2) {
          var e2;
          for (e2 in t2) return false;
          return true;
        }
        function p(t2, e2, n2) {
          Object.defineProperty(t2, e2, { enumerable: false, configurable: false, writable: true, value: n2 });
        }
        function f(t2, e2, n2) {
          var r2 = { enumerable: true, configurable: true };
          "function" == typeof n2 ? r2.get = n2 : (r2.value = n2, r2.writable = false), Object.defineProperty(t2, e2, r2);
        }
        function l(t2) {
          return !!s(t2) && !(t2.attributes && !Array.isArray(t2.attributes));
        }
        "function" == typeof Object.assign && (u = Object.assign);
        var g, y = { exports: {} }, w = "object" == typeof Reflect ? Reflect : null, v = w && "function" == typeof w.apply ? w.apply : function(t2, e2, n2) {
          return Function.prototype.apply.call(t2, e2, n2);
        };
        g = w && "function" == typeof w.ownKeys ? w.ownKeys : Object.getOwnPropertySymbols ? function(t2) {
          return Object.getOwnPropertyNames(t2).concat(Object.getOwnPropertySymbols(t2));
        } : function(t2) {
          return Object.getOwnPropertyNames(t2);
        };
        var b = Number.isNaN || function(t2) {
          return t2 != t2;
        };
        function m() {
          m.init.call(this);
        }
        y.exports = m, y.exports.once = function(t2, e2) {
          return new Promise(function(n2, r2) {
            function i2(n3) {
              t2.removeListener(e2, o2), r2(n3);
            }
            function o2() {
              "function" == typeof t2.removeListener && t2.removeListener("error", i2), n2([].slice.call(arguments));
            }
            U(t2, e2, o2, { once: true }), "error" !== e2 && function(t3, e3, n3) {
              "function" == typeof t3.on && U(t3, "error", e3, n3);
            }(t2, i2, { once: true });
          });
        }, m.EventEmitter = m, m.prototype._events = void 0, m.prototype._eventsCount = 0, m.prototype._maxListeners = void 0;
        var k = 10;
        function _(t2) {
          if ("function" != typeof t2) throw new TypeError('The "listener" argument must be of type Function. Received type ' + typeof t2);
        }
        function G(t2) {
          return void 0 === t2._maxListeners ? m.defaultMaxListeners : t2._maxListeners;
        }
        function x(t2, e2, n2, r2) {
          var i2, o2, a2, c2;
          if (_(n2), void 0 === (o2 = t2._events) ? (o2 = t2._events = /* @__PURE__ */ Object.create(null), t2._eventsCount = 0) : (void 0 !== o2.newListener && (t2.emit("newListener", e2, n2.listener ? n2.listener : n2), o2 = t2._events), a2 = o2[e2]), void 0 === a2) a2 = o2[e2] = n2, ++t2._eventsCount;
          else if ("function" == typeof a2 ? a2 = o2[e2] = r2 ? [n2, a2] : [a2, n2] : r2 ? a2.unshift(n2) : a2.push(n2), (i2 = G(t2)) > 0 && a2.length > i2 && !a2.warned) {
            a2.warned = true;
            var u2 = new Error("Possible EventEmitter memory leak detected. " + a2.length + " " + String(e2) + " listeners added. Use emitter.setMaxListeners() to increase limit");
            u2.name = "MaxListenersExceededWarning", u2.emitter = t2, u2.type = e2, u2.count = a2.length, c2 = u2, console && console.warn && console.warn(c2);
          }
          return t2;
        }
        function E() {
          if (!this.fired) return this.target.removeListener(this.type, this.wrapFn), this.fired = true, 0 === arguments.length ? this.listener.call(this.target) : this.listener.apply(this.target, arguments);
        }
        function A(t2, e2, n2) {
          var r2 = { fired: false, wrapFn: void 0, target: t2, type: e2, listener: n2 }, i2 = E.bind(r2);
          return i2.listener = n2, r2.wrapFn = i2, i2;
        }
        function L(t2, e2, n2) {
          var r2 = t2._events;
          if (void 0 === r2) return [];
          var i2 = r2[e2];
          return void 0 === i2 ? [] : "function" == typeof i2 ? n2 ? [i2.listener || i2] : [i2] : n2 ? function(t3) {
            for (var e3 = new Array(t3.length), n3 = 0; n3 < e3.length; ++n3) e3[n3] = t3[n3].listener || t3[n3];
            return e3;
          }(i2) : D(i2, i2.length);
        }
        function S(t2) {
          var e2 = this._events;
          if (void 0 !== e2) {
            var n2 = e2[t2];
            if ("function" == typeof n2) return 1;
            if (void 0 !== n2) return n2.length;
          }
          return 0;
        }
        function D(t2, e2) {
          for (var n2 = new Array(e2), r2 = 0; r2 < e2; ++r2) n2[r2] = t2[r2];
          return n2;
        }
        function U(t2, e2, n2, r2) {
          if ("function" == typeof t2.on) r2.once ? t2.once(e2, n2) : t2.on(e2, n2);
          else {
            if ("function" != typeof t2.addEventListener) throw new TypeError('The "emitter" argument must be of type EventEmitter. Received type ' + typeof t2);
            t2.addEventListener(e2, function i2(o2) {
              r2.once && t2.removeEventListener(e2, i2), n2(o2);
            });
          }
        }
        function N(t2) {
          if ("function" != typeof t2) throw new Error("obliterator/iterator: expecting a function!");
          this.next = t2;
        }
        Object.defineProperty(m, "defaultMaxListeners", { enumerable: true, get: function() {
          return k;
        }, set: function(t2) {
          if ("number" != typeof t2 || t2 < 0 || b(t2)) throw new RangeError('The value of "defaultMaxListeners" is out of range. It must be a non-negative number. Received ' + t2 + ".");
          k = t2;
        } }), m.init = function() {
          void 0 !== this._events && this._events !== Object.getPrototypeOf(this)._events || (this._events = /* @__PURE__ */ Object.create(null), this._eventsCount = 0), this._maxListeners = this._maxListeners || void 0;
        }, m.prototype.setMaxListeners = function(t2) {
          if ("number" != typeof t2 || t2 < 0 || b(t2)) throw new RangeError('The value of "n" is out of range. It must be a non-negative number. Received ' + t2 + ".");
          return this._maxListeners = t2, this;
        }, m.prototype.getMaxListeners = function() {
          return G(this);
        }, m.prototype.emit = function(t2) {
          for (var e2 = [], n2 = 1; n2 < arguments.length; n2++) e2.push(arguments[n2]);
          var r2 = "error" === t2, i2 = this._events;
          if (void 0 !== i2) r2 = r2 && void 0 === i2.error;
          else if (!r2) return false;
          if (r2) {
            var o2;
            if (e2.length > 0 && (o2 = e2[0]), o2 instanceof Error) throw o2;
            var a2 = new Error("Unhandled error." + (o2 ? " (" + o2.message + ")" : ""));
            throw a2.context = o2, a2;
          }
          var c2 = i2[t2];
          if (void 0 === c2) return false;
          if ("function" == typeof c2) v(c2, this, e2);
          else {
            var u2 = c2.length, d2 = D(c2, u2);
            for (n2 = 0; n2 < u2; ++n2) v(d2[n2], this, e2);
          }
          return true;
        }, m.prototype.addListener = function(t2, e2) {
          return x(this, t2, e2, false);
        }, m.prototype.on = m.prototype.addListener, m.prototype.prependListener = function(t2, e2) {
          return x(this, t2, e2, true);
        }, m.prototype.once = function(t2, e2) {
          return _(e2), this.on(t2, A(this, t2, e2)), this;
        }, m.prototype.prependOnceListener = function(t2, e2) {
          return _(e2), this.prependListener(t2, A(this, t2, e2)), this;
        }, m.prototype.removeListener = function(t2, e2) {
          var n2, r2, i2, o2, a2;
          if (_(e2), void 0 === (r2 = this._events)) return this;
          if (void 0 === (n2 = r2[t2])) return this;
          if (n2 === e2 || n2.listener === e2) 0 == --this._eventsCount ? this._events = /* @__PURE__ */ Object.create(null) : (delete r2[t2], r2.removeListener && this.emit("removeListener", t2, n2.listener || e2));
          else if ("function" != typeof n2) {
            for (i2 = -1, o2 = n2.length - 1; o2 >= 0; o2--) if (n2[o2] === e2 || n2[o2].listener === e2) {
              a2 = n2[o2].listener, i2 = o2;
              break;
            }
            if (i2 < 0) return this;
            0 === i2 ? n2.shift() : function(t3, e3) {
              for (; e3 + 1 < t3.length; e3++) t3[e3] = t3[e3 + 1];
              t3.pop();
            }(n2, i2), 1 === n2.length && (r2[t2] = n2[0]), void 0 !== r2.removeListener && this.emit("removeListener", t2, a2 || e2);
          }
          return this;
        }, m.prototype.off = m.prototype.removeListener, m.prototype.removeAllListeners = function(t2) {
          var e2, n2, r2;
          if (void 0 === (n2 = this._events)) return this;
          if (void 0 === n2.removeListener) return 0 === arguments.length ? (this._events = /* @__PURE__ */ Object.create(null), this._eventsCount = 0) : void 0 !== n2[t2] && (0 == --this._eventsCount ? this._events = /* @__PURE__ */ Object.create(null) : delete n2[t2]), this;
          if (0 === arguments.length) {
            var i2, o2 = Object.keys(n2);
            for (r2 = 0; r2 < o2.length; ++r2) "removeListener" !== (i2 = o2[r2]) && this.removeAllListeners(i2);
            return this.removeAllListeners("removeListener"), this._events = /* @__PURE__ */ Object.create(null), this._eventsCount = 0, this;
          }
          if ("function" == typeof (e2 = n2[t2])) this.removeListener(t2, e2);
          else if (void 0 !== e2) for (r2 = e2.length - 1; r2 >= 0; r2--) this.removeListener(t2, e2[r2]);
          return this;
        }, m.prototype.listeners = function(t2) {
          return L(this, t2, true);
        }, m.prototype.rawListeners = function(t2) {
          return L(this, t2, false);
        }, m.listenerCount = function(t2, e2) {
          return "function" == typeof t2.listenerCount ? t2.listenerCount(e2) : S.call(t2, e2);
        }, m.prototype.listenerCount = S, m.prototype.eventNames = function() {
          return this._eventsCount > 0 ? g(this._events) : [];
        }, "undefined" != typeof Symbol && (N.prototype[Symbol.iterator] = function() {
          return this;
        }), N.of = function() {
          var t2 = arguments, e2 = t2.length, n2 = 0;
          return new N(function() {
            return n2 >= e2 ? { done: true } : { done: false, value: t2[n2++] };
          });
        }, N.empty = function() {
          return new N(function() {
            return { done: true };
          });
        }, N.fromSequence = function(t2) {
          var e2 = 0, n2 = t2.length;
          return new N(function() {
            return e2 >= n2 ? { done: true } : { done: false, value: t2[e2++] };
          });
        }, N.is = function(t2) {
          return t2 instanceof N || "object" == typeof t2 && null !== t2 && "function" == typeof t2.next;
        };
        var O = N, j = {};
        j.ARRAY_BUFFER_SUPPORT = "undefined" != typeof ArrayBuffer, j.SYMBOL_SUPPORT = "undefined" != typeof Symbol;
        var C = O, M = j, z = M.ARRAY_BUFFER_SUPPORT, W = M.SYMBOL_SUPPORT;
        var P = function(t2) {
          var e2 = function(t3) {
            return "string" == typeof t3 || Array.isArray(t3) || z && ArrayBuffer.isView(t3) ? C.fromSequence(t3) : "object" != typeof t3 || null === t3 ? null : W && "function" == typeof t3[Symbol.iterator] ? t3[Symbol.iterator]() : "function" == typeof t3.next ? t3 : null;
          }(t2);
          if (!e2) throw new Error("obliterator: target is not iterable nor a valid iterator.");
          return e2;
        }, R = P, K = function(t2, e2) {
          for (var n2, r2 = arguments.length > 1 ? e2 : 1 / 0, i2 = r2 !== 1 / 0 ? new Array(r2) : [], o2 = 0, a2 = R(t2); ; ) {
            if (o2 === r2) return i2;
            if ((n2 = a2.next()).done) return o2 !== e2 && (i2.length = o2), i2;
            i2[o2++] = n2.value;
          }
        }, T = function(t2) {
          function n2(e2) {
            var n3;
            return (n3 = t2.call(this) || this).name = "GraphError", n3.message = e2, n3;
          }
          return e(n2, t2), n2;
        }(a(Error)), B = function(t2) {
          function n2(e2) {
            var r2;
            return (r2 = t2.call(this, e2) || this).name = "InvalidArgumentsGraphError", "function" == typeof Error.captureStackTrace && Error.captureStackTrace(c(r2), n2.prototype.constructor), r2;
          }
          return e(n2, t2), n2;
        }(T), F = function(t2) {
          function n2(e2) {
            var r2;
            return (r2 = t2.call(this, e2) || this).name = "NotFoundGraphError", "function" == typeof Error.captureStackTrace && Error.captureStackTrace(c(r2), n2.prototype.constructor), r2;
          }
          return e(n2, t2), n2;
        }(T), I = function(t2) {
          function n2(e2) {
            var r2;
            return (r2 = t2.call(this, e2) || this).name = "UsageGraphError", "function" == typeof Error.captureStackTrace && Error.captureStackTrace(c(r2), n2.prototype.constructor), r2;
          }
          return e(n2, t2), n2;
        }(T);
        function Y(t2, e2) {
          this.key = t2, this.attributes = e2, this.clear();
        }
        function q(t2, e2) {
          this.key = t2, this.attributes = e2, this.clear();
        }
        function J(t2, e2) {
          this.key = t2, this.attributes = e2, this.clear();
        }
        function V(t2, e2, n2, r2, i2) {
          this.key = e2, this.attributes = i2, this.undirected = t2, this.source = n2, this.target = r2;
        }
        Y.prototype.clear = function() {
          this.inDegree = 0, this.outDegree = 0, this.undirectedDegree = 0, this.undirectedLoops = 0, this.directedLoops = 0, this.in = {}, this.out = {}, this.undirected = {};
        }, q.prototype.clear = function() {
          this.inDegree = 0, this.outDegree = 0, this.directedLoops = 0, this.in = {}, this.out = {};
        }, J.prototype.clear = function() {
          this.undirectedDegree = 0, this.undirectedLoops = 0, this.undirected = {};
        }, V.prototype.attach = function() {
          var t2 = "out", e2 = "in";
          this.undirected && (t2 = e2 = "undirected");
          var n2 = this.source.key, r2 = this.target.key;
          this.source[t2][r2] = this, this.undirected && n2 === r2 || (this.target[e2][n2] = this);
        }, V.prototype.attachMulti = function() {
          var t2 = "out", e2 = "in", n2 = this.source.key, r2 = this.target.key;
          this.undirected && (t2 = e2 = "undirected");
          var i2 = this.source[t2], o2 = i2[r2];
          if (void 0 === o2) return i2[r2] = this, void (this.undirected && n2 === r2 || (this.target[e2][n2] = this));
          o2.previous = this, this.next = o2, i2[r2] = this, this.target[e2][n2] = this;
        }, V.prototype.detach = function() {
          var t2 = this.source.key, e2 = this.target.key, n2 = "out", r2 = "in";
          this.undirected && (n2 = r2 = "undirected"), delete this.source[n2][e2], delete this.target[r2][t2];
        }, V.prototype.detachMulti = function() {
          var t2 = this.source.key, e2 = this.target.key, n2 = "out", r2 = "in";
          this.undirected && (n2 = r2 = "undirected"), void 0 === this.previous ? void 0 === this.next ? (delete this.source[n2][e2], delete this.target[r2][t2]) : (this.next.previous = void 0, this.source[n2][e2] = this.next, this.target[r2][t2] = this.next) : (this.previous.next = this.next, void 0 !== this.next && (this.next.previous = this.previous));
        };
        function H(t2, e2, n2, r2, i2, o2, a2) {
          var c2, u2, d2, s2;
          if (r2 = "" + r2, 0 === n2) {
            if (!(c2 = t2._nodes.get(r2))) throw new F("Graph.".concat(e2, ': could not find the "').concat(r2, '" node in the graph.'));
            d2 = i2, s2 = o2;
          } else if (3 === n2) {
            if (i2 = "" + i2, !(u2 = t2._edges.get(i2))) throw new F("Graph.".concat(e2, ': could not find the "').concat(i2, '" edge in the graph.'));
            var h2 = u2.source.key, p2 = u2.target.key;
            if (r2 === h2) c2 = u2.target;
            else {
              if (r2 !== p2) throw new F("Graph.".concat(e2, ': the "').concat(r2, '" node is not attached to the "').concat(i2, '" edge (').concat(h2, ", ").concat(p2, ")."));
              c2 = u2.source;
            }
            d2 = o2, s2 = a2;
          } else {
            if (!(u2 = t2._edges.get(r2))) throw new F("Graph.".concat(e2, ': could not find the "').concat(r2, '" edge in the graph.'));
            c2 = 1 === n2 ? u2.source : u2.target, d2 = i2, s2 = o2;
          }
          return [c2, d2, s2];
        }
        var Q = [{ name: function(t2) {
          return "get".concat(t2, "Attribute");
        }, attacher: function(t2, e2, n2) {
          t2.prototype[e2] = function(t3, r2, i2) {
            var o2 = H(this, e2, n2, t3, r2, i2), a2 = o2[0], c2 = o2[1];
            return a2.attributes[c2];
          };
        } }, { name: function(t2) {
          return "get".concat(t2, "Attributes");
        }, attacher: function(t2, e2, n2) {
          t2.prototype[e2] = function(t3, r2) {
            return H(this, e2, n2, t3, r2)[0].attributes;
          };
        } }, { name: function(t2) {
          return "has".concat(t2, "Attribute");
        }, attacher: function(t2, e2, n2) {
          t2.prototype[e2] = function(t3, r2, i2) {
            var o2 = H(this, e2, n2, t3, r2, i2), a2 = o2[0], c2 = o2[1];
            return a2.attributes.hasOwnProperty(c2);
          };
        } }, { name: function(t2) {
          return "set".concat(t2, "Attribute");
        }, attacher: function(t2, e2, n2) {
          t2.prototype[e2] = function(t3, r2, i2, o2) {
            var a2 = H(this, e2, n2, t3, r2, i2, o2), c2 = a2[0], u2 = a2[1], d2 = a2[2];
            return c2.attributes[u2] = d2, this.emit("nodeAttributesUpdated", { key: c2.key, type: "set", attributes: c2.attributes, name: u2 }), this;
          };
        } }, { name: function(t2) {
          return "update".concat(t2, "Attribute");
        }, attacher: function(t2, e2, n2) {
          t2.prototype[e2] = function(t3, r2, i2, o2) {
            var a2 = H(this, e2, n2, t3, r2, i2, o2), c2 = a2[0], u2 = a2[1], d2 = a2[2];
            if ("function" != typeof d2) throw new B("Graph.".concat(e2, ": updater should be a function."));
            var s2 = c2.attributes, h2 = d2(s2[u2]);
            return s2[u2] = h2, this.emit("nodeAttributesUpdated", { key: c2.key, type: "set", attributes: c2.attributes, name: u2 }), this;
          };
        } }, { name: function(t2) {
          return "remove".concat(t2, "Attribute");
        }, attacher: function(t2, e2, n2) {
          t2.prototype[e2] = function(t3, r2, i2) {
            var o2 = H(this, e2, n2, t3, r2, i2), a2 = o2[0], c2 = o2[1];
            return delete a2.attributes[c2], this.emit("nodeAttributesUpdated", { key: a2.key, type: "remove", attributes: a2.attributes, name: c2 }), this;
          };
        } }, { name: function(t2) {
          return "replace".concat(t2, "Attributes");
        }, attacher: function(t2, e2, n2) {
          t2.prototype[e2] = function(t3, r2, i2) {
            var o2 = H(this, e2, n2, t3, r2, i2), a2 = o2[0], c2 = o2[1];
            if (!s(c2)) throw new B("Graph.".concat(e2, ": provided attributes are not a plain object."));
            return a2.attributes = c2, this.emit("nodeAttributesUpdated", { key: a2.key, type: "replace", attributes: a2.attributes }), this;
          };
        } }, { name: function(t2) {
          return "merge".concat(t2, "Attributes");
        }, attacher: function(t2, e2, n2) {
          t2.prototype[e2] = function(t3, r2, i2) {
            var o2 = H(this, e2, n2, t3, r2, i2), a2 = o2[0], c2 = o2[1];
            if (!s(c2)) throw new B("Graph.".concat(e2, ": provided attributes are not a plain object."));
            return u(a2.attributes, c2), this.emit("nodeAttributesUpdated", { key: a2.key, type: "merge", attributes: a2.attributes, data: c2 }), this;
          };
        } }, { name: function(t2) {
          return "update".concat(t2, "Attributes");
        }, attacher: function(t2, e2, n2) {
          t2.prototype[e2] = function(t3, r2, i2) {
            var o2 = H(this, e2, n2, t3, r2, i2), a2 = o2[0], c2 = o2[1];
            if ("function" != typeof c2) throw new B("Graph.".concat(e2, ": provided updater is not a function."));
            return a2.attributes = c2(a2.attributes), this.emit("nodeAttributesUpdated", { key: a2.key, type: "update", attributes: a2.attributes }), this;
          };
        } }];
        var X = [{ name: function(t2) {
          return "get".concat(t2, "Attribute");
        }, attacher: function(t2, e2, n2) {
          t2.prototype[e2] = function(t3, r2) {
            var i2;
            if ("mixed" !== this.type && "mixed" !== n2 && n2 !== this.type) throw new I("Graph.".concat(e2, ": cannot find this type of edges in your ").concat(this.type, " graph."));
            if (arguments.length > 2) {
              if (this.multi) throw new I("Graph.".concat(e2, ": cannot use a {source,target} combo when asking about an edge's attributes in a MultiGraph since we cannot infer the one you want information about."));
              var o2 = "" + t3, a2 = "" + r2;
              if (r2 = arguments[2], !(i2 = d(this, o2, a2, n2))) throw new F("Graph.".concat(e2, ': could not find an edge for the given path ("').concat(o2, '" - "').concat(a2, '").'));
            } else {
              if ("mixed" !== n2) throw new I("Graph.".concat(e2, ": calling this method with only a key (vs. a source and target) does not make sense since an edge with this key could have the other type."));
              if (t3 = "" + t3, !(i2 = this._edges.get(t3))) throw new F("Graph.".concat(e2, ': could not find the "').concat(t3, '" edge in the graph.'));
            }
            return i2.attributes[r2];
          };
        } }, { name: function(t2) {
          return "get".concat(t2, "Attributes");
        }, attacher: function(t2, e2, n2) {
          t2.prototype[e2] = function(t3) {
            var r2;
            if ("mixed" !== this.type && "mixed" !== n2 && n2 !== this.type) throw new I("Graph.".concat(e2, ": cannot find this type of edges in your ").concat(this.type, " graph."));
            if (arguments.length > 1) {
              if (this.multi) throw new I("Graph.".concat(e2, ": cannot use a {source,target} combo when asking about an edge's attributes in a MultiGraph since we cannot infer the one you want information about."));
              var i2 = "" + t3, o2 = "" + arguments[1];
              if (!(r2 = d(this, i2, o2, n2))) throw new F("Graph.".concat(e2, ': could not find an edge for the given path ("').concat(i2, '" - "').concat(o2, '").'));
            } else {
              if ("mixed" !== n2) throw new I("Graph.".concat(e2, ": calling this method with only a key (vs. a source and target) does not make sense since an edge with this key could have the other type."));
              if (t3 = "" + t3, !(r2 = this._edges.get(t3))) throw new F("Graph.".concat(e2, ': could not find the "').concat(t3, '" edge in the graph.'));
            }
            return r2.attributes;
          };
        } }, { name: function(t2) {
          return "has".concat(t2, "Attribute");
        }, attacher: function(t2, e2, n2) {
          t2.prototype[e2] = function(t3, r2) {
            var i2;
            if ("mixed" !== this.type && "mixed" !== n2 && n2 !== this.type) throw new I("Graph.".concat(e2, ": cannot find this type of edges in your ").concat(this.type, " graph."));
            if (arguments.length > 2) {
              if (this.multi) throw new I("Graph.".concat(e2, ": cannot use a {source,target} combo when asking about an edge's attributes in a MultiGraph since we cannot infer the one you want information about."));
              var o2 = "" + t3, a2 = "" + r2;
              if (r2 = arguments[2], !(i2 = d(this, o2, a2, n2))) throw new F("Graph.".concat(e2, ': could not find an edge for the given path ("').concat(o2, '" - "').concat(a2, '").'));
            } else {
              if ("mixed" !== n2) throw new I("Graph.".concat(e2, ": calling this method with only a key (vs. a source and target) does not make sense since an edge with this key could have the other type."));
              if (t3 = "" + t3, !(i2 = this._edges.get(t3))) throw new F("Graph.".concat(e2, ': could not find the "').concat(t3, '" edge in the graph.'));
            }
            return i2.attributes.hasOwnProperty(r2);
          };
        } }, { name: function(t2) {
          return "set".concat(t2, "Attribute");
        }, attacher: function(t2, e2, n2) {
          t2.prototype[e2] = function(t3, r2, i2) {
            var o2;
            if ("mixed" !== this.type && "mixed" !== n2 && n2 !== this.type) throw new I("Graph.".concat(e2, ": cannot find this type of edges in your ").concat(this.type, " graph."));
            if (arguments.length > 3) {
              if (this.multi) throw new I("Graph.".concat(e2, ": cannot use a {source,target} combo when asking about an edge's attributes in a MultiGraph since we cannot infer the one you want information about."));
              var a2 = "" + t3, c2 = "" + r2;
              if (r2 = arguments[2], i2 = arguments[3], !(o2 = d(this, a2, c2, n2))) throw new F("Graph.".concat(e2, ': could not find an edge for the given path ("').concat(a2, '" - "').concat(c2, '").'));
            } else {
              if ("mixed" !== n2) throw new I("Graph.".concat(e2, ": calling this method with only a key (vs. a source and target) does not make sense since an edge with this key could have the other type."));
              if (t3 = "" + t3, !(o2 = this._edges.get(t3))) throw new F("Graph.".concat(e2, ': could not find the "').concat(t3, '" edge in the graph.'));
            }
            return o2.attributes[r2] = i2, this.emit("edgeAttributesUpdated", { key: o2.key, type: "set", attributes: o2.attributes, name: r2 }), this;
          };
        } }, { name: function(t2) {
          return "update".concat(t2, "Attribute");
        }, attacher: function(t2, e2, n2) {
          t2.prototype[e2] = function(t3, r2, i2) {
            var o2;
            if ("mixed" !== this.type && "mixed" !== n2 && n2 !== this.type) throw new I("Graph.".concat(e2, ": cannot find this type of edges in your ").concat(this.type, " graph."));
            if (arguments.length > 3) {
              if (this.multi) throw new I("Graph.".concat(e2, ": cannot use a {source,target} combo when asking about an edge's attributes in a MultiGraph since we cannot infer the one you want information about."));
              var a2 = "" + t3, c2 = "" + r2;
              if (r2 = arguments[2], i2 = arguments[3], !(o2 = d(this, a2, c2, n2))) throw new F("Graph.".concat(e2, ': could not find an edge for the given path ("').concat(a2, '" - "').concat(c2, '").'));
            } else {
              if ("mixed" !== n2) throw new I("Graph.".concat(e2, ": calling this method with only a key (vs. a source and target) does not make sense since an edge with this key could have the other type."));
              if (t3 = "" + t3, !(o2 = this._edges.get(t3))) throw new F("Graph.".concat(e2, ': could not find the "').concat(t3, '" edge in the graph.'));
            }
            if ("function" != typeof i2) throw new B("Graph.".concat(e2, ": updater should be a function."));
            return o2.attributes[r2] = i2(o2.attributes[r2]), this.emit("edgeAttributesUpdated", { key: o2.key, type: "set", attributes: o2.attributes, name: r2 }), this;
          };
        } }, { name: function(t2) {
          return "remove".concat(t2, "Attribute");
        }, attacher: function(t2, e2, n2) {
          t2.prototype[e2] = function(t3, r2) {
            var i2;
            if ("mixed" !== this.type && "mixed" !== n2 && n2 !== this.type) throw new I("Graph.".concat(e2, ": cannot find this type of edges in your ").concat(this.type, " graph."));
            if (arguments.length > 2) {
              if (this.multi) throw new I("Graph.".concat(e2, ": cannot use a {source,target} combo when asking about an edge's attributes in a MultiGraph since we cannot infer the one you want information about."));
              var o2 = "" + t3, a2 = "" + r2;
              if (r2 = arguments[2], !(i2 = d(this, o2, a2, n2))) throw new F("Graph.".concat(e2, ': could not find an edge for the given path ("').concat(o2, '" - "').concat(a2, '").'));
            } else {
              if ("mixed" !== n2) throw new I("Graph.".concat(e2, ": calling this method with only a key (vs. a source and target) does not make sense since an edge with this key could have the other type."));
              if (t3 = "" + t3, !(i2 = this._edges.get(t3))) throw new F("Graph.".concat(e2, ': could not find the "').concat(t3, '" edge in the graph.'));
            }
            return delete i2.attributes[r2], this.emit("edgeAttributesUpdated", { key: i2.key, type: "remove", attributes: i2.attributes, name: r2 }), this;
          };
        } }, { name: function(t2) {
          return "replace".concat(t2, "Attributes");
        }, attacher: function(t2, e2, n2) {
          t2.prototype[e2] = function(t3, r2) {
            var i2;
            if ("mixed" !== this.type && "mixed" !== n2 && n2 !== this.type) throw new I("Graph.".concat(e2, ": cannot find this type of edges in your ").concat(this.type, " graph."));
            if (arguments.length > 2) {
              if (this.multi) throw new I("Graph.".concat(e2, ": cannot use a {source,target} combo when asking about an edge's attributes in a MultiGraph since we cannot infer the one you want information about."));
              var o2 = "" + t3, a2 = "" + r2;
              if (r2 = arguments[2], !(i2 = d(this, o2, a2, n2))) throw new F("Graph.".concat(e2, ': could not find an edge for the given path ("').concat(o2, '" - "').concat(a2, '").'));
            } else {
              if ("mixed" !== n2) throw new I("Graph.".concat(e2, ": calling this method with only a key (vs. a source and target) does not make sense since an edge with this key could have the other type."));
              if (t3 = "" + t3, !(i2 = this._edges.get(t3))) throw new F("Graph.".concat(e2, ': could not find the "').concat(t3, '" edge in the graph.'));
            }
            if (!s(r2)) throw new B("Graph.".concat(e2, ": provided attributes are not a plain object."));
            return i2.attributes = r2, this.emit("edgeAttributesUpdated", { key: i2.key, type: "replace", attributes: i2.attributes }), this;
          };
        } }, { name: function(t2) {
          return "merge".concat(t2, "Attributes");
        }, attacher: function(t2, e2, n2) {
          t2.prototype[e2] = function(t3, r2) {
            var i2;
            if ("mixed" !== this.type && "mixed" !== n2 && n2 !== this.type) throw new I("Graph.".concat(e2, ": cannot find this type of edges in your ").concat(this.type, " graph."));
            if (arguments.length > 2) {
              if (this.multi) throw new I("Graph.".concat(e2, ": cannot use a {source,target} combo when asking about an edge's attributes in a MultiGraph since we cannot infer the one you want information about."));
              var o2 = "" + t3, a2 = "" + r2;
              if (r2 = arguments[2], !(i2 = d(this, o2, a2, n2))) throw new F("Graph.".concat(e2, ': could not find an edge for the given path ("').concat(o2, '" - "').concat(a2, '").'));
            } else {
              if ("mixed" !== n2) throw new I("Graph.".concat(e2, ": calling this method with only a key (vs. a source and target) does not make sense since an edge with this key could have the other type."));
              if (t3 = "" + t3, !(i2 = this._edges.get(t3))) throw new F("Graph.".concat(e2, ': could not find the "').concat(t3, '" edge in the graph.'));
            }
            if (!s(r2)) throw new B("Graph.".concat(e2, ": provided attributes are not a plain object."));
            return u(i2.attributes, r2), this.emit("edgeAttributesUpdated", { key: i2.key, type: "merge", attributes: i2.attributes, data: r2 }), this;
          };
        } }, { name: function(t2) {
          return "update".concat(t2, "Attributes");
        }, attacher: function(t2, e2, n2) {
          t2.prototype[e2] = function(t3, r2) {
            var i2;
            if ("mixed" !== this.type && "mixed" !== n2 && n2 !== this.type) throw new I("Graph.".concat(e2, ": cannot find this type of edges in your ").concat(this.type, " graph."));
            if (arguments.length > 2) {
              if (this.multi) throw new I("Graph.".concat(e2, ": cannot use a {source,target} combo when asking about an edge's attributes in a MultiGraph since we cannot infer the one you want information about."));
              var o2 = "" + t3, a2 = "" + r2;
              if (r2 = arguments[2], !(i2 = d(this, o2, a2, n2))) throw new F("Graph.".concat(e2, ': could not find an edge for the given path ("').concat(o2, '" - "').concat(a2, '").'));
            } else {
              if ("mixed" !== n2) throw new I("Graph.".concat(e2, ": calling this method with only a key (vs. a source and target) does not make sense since an edge with this key could have the other type."));
              if (t3 = "" + t3, !(i2 = this._edges.get(t3))) throw new F("Graph.".concat(e2, ': could not find the "').concat(t3, '" edge in the graph.'));
            }
            if ("function" != typeof r2) throw new B("Graph.".concat(e2, ": provided updater is not a function."));
            return i2.attributes = r2(i2.attributes), this.emit("edgeAttributesUpdated", { key: i2.key, type: "update", attributes: i2.attributes }), this;
          };
        } }];
        var Z = O, $ = P, tt = function() {
          var t2 = arguments, e2 = null, n2 = -1;
          return new Z(function() {
            for (var r2 = null; ; ) {
              if (null === e2) {
                if (++n2 >= t2.length) return { done: true };
                e2 = $(t2[n2]);
              }
              if (true !== (r2 = e2.next()).done) break;
              e2 = null;
            }
            return r2;
          });
        }, et = [{ name: "edges", type: "mixed" }, { name: "inEdges", type: "directed", direction: "in" }, { name: "outEdges", type: "directed", direction: "out" }, { name: "inboundEdges", type: "mixed", direction: "in" }, { name: "outboundEdges", type: "mixed", direction: "out" }, { name: "directedEdges", type: "directed" }, { name: "undirectedEdges", type: "undirected" }];
        function nt(t2, e2, n2, r2) {
          var i2 = false;
          for (var o2 in e2) if (o2 !== r2) {
            var a2 = e2[o2];
            if (i2 = n2(a2.key, a2.attributes, a2.source.key, a2.target.key, a2.source.attributes, a2.target.attributes, a2.undirected), t2 && i2) return a2.key;
          }
        }
        function rt(t2, e2, n2, r2) {
          var i2, o2, a2, c2 = false;
          for (var u2 in e2) if (u2 !== r2) {
            i2 = e2[u2];
            do {
              if (o2 = i2.source, a2 = i2.target, c2 = n2(i2.key, i2.attributes, o2.key, a2.key, o2.attributes, a2.attributes, i2.undirected), t2 && c2) return i2.key;
              i2 = i2.next;
            } while (void 0 !== i2);
          }
        }
        function it(t2, e2) {
          var n2, r2 = Object.keys(t2), i2 = r2.length, o2 = 0;
          return new O(function() {
            do {
              if (n2) n2 = n2.next;
              else {
                if (o2 >= i2) return { done: true };
                var a2 = r2[o2++];
                if (a2 === e2) {
                  n2 = void 0;
                  continue;
                }
                n2 = t2[a2];
              }
            } while (!n2);
            return { done: false, value: { edge: n2.key, attributes: n2.attributes, source: n2.source.key, target: n2.target.key, sourceAttributes: n2.source.attributes, targetAttributes: n2.target.attributes, undirected: n2.undirected } };
          });
        }
        function ot(t2, e2, n2, r2) {
          var i2 = e2[n2];
          if (i2) {
            var o2 = i2.source, a2 = i2.target;
            return r2(i2.key, i2.attributes, o2.key, a2.key, o2.attributes, a2.attributes, i2.undirected) && t2 ? i2.key : void 0;
          }
        }
        function at(t2, e2, n2, r2) {
          var i2 = e2[n2];
          if (i2) {
            var o2 = false;
            do {
              if (o2 = r2(i2.key, i2.attributes, i2.source.key, i2.target.key, i2.source.attributes, i2.target.attributes, i2.undirected), t2 && o2) return i2.key;
              i2 = i2.next;
            } while (void 0 !== i2);
          }
        }
        function ct(t2, e2) {
          var n2 = t2[e2];
          return void 0 !== n2.next ? new O(function() {
            if (!n2) return { done: true };
            var t3 = { edge: n2.key, attributes: n2.attributes, source: n2.source.key, target: n2.target.key, sourceAttributes: n2.source.attributes, targetAttributes: n2.target.attributes, undirected: n2.undirected };
            return n2 = n2.next, { done: false, value: t3 };
          }) : O.of({ edge: n2.key, attributes: n2.attributes, source: n2.source.key, target: n2.target.key, sourceAttributes: n2.source.attributes, targetAttributes: n2.target.attributes, undirected: n2.undirected });
        }
        function ut(t2, e2) {
          if (0 === t2.size) return [];
          if ("mixed" === e2 || e2 === t2.type) return "function" == typeof Array.from ? Array.from(t2._edges.keys()) : K(t2._edges.keys(), t2._edges.size);
          for (var n2, r2, i2 = "undirected" === e2 ? t2.undirectedSize : t2.directedSize, o2 = new Array(i2), a2 = "undirected" === e2, c2 = t2._edges.values(), u2 = 0; true !== (n2 = c2.next()).done; ) (r2 = n2.value).undirected === a2 && (o2[u2++] = r2.key);
          return o2;
        }
        function dt(t2, e2, n2, r2) {
          if (0 !== e2.size) {
            for (var i2, o2, a2 = "mixed" !== n2 && n2 !== e2.type, c2 = "undirected" === n2, u2 = false, d2 = e2._edges.values(); true !== (i2 = d2.next()).done; ) if (o2 = i2.value, !a2 || o2.undirected === c2) {
              var s2 = o2, h2 = s2.key, p2 = s2.attributes, f2 = s2.source, l2 = s2.target;
              if (u2 = r2(h2, p2, f2.key, l2.key, f2.attributes, l2.attributes, o2.undirected), t2 && u2) return h2;
            }
          }
        }
        function st(t2, e2) {
          if (0 === t2.size) return O.empty();
          var n2 = "mixed" !== e2 && e2 !== t2.type, r2 = "undirected" === e2, i2 = t2._edges.values();
          return new O(function() {
            for (var t3, e3; ; ) {
              if ((t3 = i2.next()).done) return t3;
              if (e3 = t3.value, !n2 || e3.undirected === r2) break;
            }
            return { value: { edge: e3.key, attributes: e3.attributes, source: e3.source.key, target: e3.target.key, sourceAttributes: e3.source.attributes, targetAttributes: e3.target.attributes, undirected: e3.undirected }, done: false };
          });
        }
        function ht(t2, e2, n2, r2, i2, o2) {
          var a2, c2 = e2 ? rt : nt;
          if ("undirected" !== n2) {
            if ("out" !== r2 && (a2 = c2(t2, i2.in, o2), t2 && a2)) return a2;
            if ("in" !== r2 && (a2 = c2(t2, i2.out, o2, r2 ? void 0 : i2.key), t2 && a2)) return a2;
          }
          if ("directed" !== n2 && (a2 = c2(t2, i2.undirected, o2), t2 && a2)) return a2;
        }
        function pt(t2, e2, n2, r2) {
          var i2 = [];
          return ht(false, t2, e2, n2, r2, function(t3) {
            i2.push(t3);
          }), i2;
        }
        function ft(t2, e2, n2) {
          var r2 = O.empty();
          return "undirected" !== t2 && ("out" !== e2 && void 0 !== n2.in && (r2 = tt(r2, it(n2.in))), "in" !== e2 && void 0 !== n2.out && (r2 = tt(r2, it(n2.out, e2 ? void 0 : n2.key)))), "directed" !== t2 && void 0 !== n2.undirected && (r2 = tt(r2, it(n2.undirected))), r2;
        }
        function lt(t2, e2, n2, r2, i2, o2, a2) {
          var c2, u2 = n2 ? at : ot;
          if ("undirected" !== e2) {
            if (void 0 !== i2.in && "out" !== r2 && (c2 = u2(t2, i2.in, o2, a2), t2 && c2)) return c2;
            if (void 0 !== i2.out && "in" !== r2 && (r2 || i2.key !== o2) && (c2 = u2(t2, i2.out, o2, a2), t2 && c2)) return c2;
          }
          if ("directed" !== e2 && void 0 !== i2.undirected && (c2 = u2(t2, i2.undirected, o2, a2), t2 && c2)) return c2;
        }
        function gt(t2, e2, n2, r2, i2) {
          var o2 = [];
          return lt(false, t2, e2, n2, r2, i2, function(t3) {
            o2.push(t3);
          }), o2;
        }
        function yt(t2, e2, n2, r2) {
          var i2 = O.empty();
          return "undirected" !== t2 && (void 0 !== n2.in && "out" !== e2 && r2 in n2.in && (i2 = tt(i2, ct(n2.in, r2))), void 0 !== n2.out && "in" !== e2 && r2 in n2.out && (e2 || n2.key !== r2) && (i2 = tt(i2, ct(n2.out, r2)))), "directed" !== t2 && void 0 !== n2.undirected && r2 in n2.undirected && (i2 = tt(i2, ct(n2.undirected, r2))), i2;
        }
        var wt = [{ name: "neighbors", type: "mixed" }, { name: "inNeighbors", type: "directed", direction: "in" }, { name: "outNeighbors", type: "directed", direction: "out" }, { name: "inboundNeighbors", type: "mixed", direction: "in" }, { name: "outboundNeighbors", type: "mixed", direction: "out" }, { name: "directedNeighbors", type: "directed" }, { name: "undirectedNeighbors", type: "undirected" }];
        function vt() {
          this.A = null, this.B = null;
        }
        function bt(t2, e2, n2, r2, i2) {
          for (var o2 in r2) {
            var a2 = r2[o2], c2 = a2.source, u2 = a2.target, d2 = c2 === n2 ? u2 : c2;
            if (!e2 || !e2.has(d2.key)) {
              var s2 = i2(d2.key, d2.attributes);
              if (t2 && s2) return d2.key;
            }
          }
        }
        function mt(t2, e2, n2, r2, i2) {
          if ("mixed" !== e2) {
            if ("undirected" === e2) return bt(t2, null, r2, r2.undirected, i2);
            if ("string" == typeof n2) return bt(t2, null, r2, r2[n2], i2);
          }
          var o2, a2 = new vt();
          if ("undirected" !== e2) {
            if ("out" !== n2) {
              if (o2 = bt(t2, null, r2, r2.in, i2), t2 && o2) return o2;
              a2.wrap(r2.in);
            }
            if ("in" !== n2) {
              if (o2 = bt(t2, a2, r2, r2.out, i2), t2 && o2) return o2;
              a2.wrap(r2.out);
            }
          }
          if ("directed" !== e2 && (o2 = bt(t2, a2, r2, r2.undirected, i2), t2 && o2)) return o2;
        }
        function kt(t2, e2, n2) {
          var r2 = Object.keys(n2), i2 = r2.length, o2 = 0;
          return new O(function() {
            var a2 = null;
            do {
              if (o2 >= i2) return t2 && t2.wrap(n2), { done: true };
              var c2 = n2[r2[o2++]], u2 = c2.source, d2 = c2.target;
              a2 = u2 === e2 ? d2 : u2, t2 && t2.has(a2.key) && (a2 = null);
            } while (null === a2);
            return { done: false, value: { neighbor: a2.key, attributes: a2.attributes } };
          });
        }
        function _t(t2, e2) {
          var n2 = e2.name, r2 = e2.type, i2 = e2.direction;
          t2.prototype[n2] = function(t3) {
            if ("mixed" !== r2 && "mixed" !== this.type && r2 !== this.type) return [];
            t3 = "" + t3;
            var e3 = this._nodes.get(t3);
            if (void 0 === e3) throw new F("Graph.".concat(n2, ': could not find the "').concat(t3, '" node in the graph.'));
            return function(t4, e4, n3) {
              if ("mixed" !== t4) {
                if ("undirected" === t4) return Object.keys(n3.undirected);
                if ("string" == typeof e4) return Object.keys(n3[e4]);
              }
              var r3 = [];
              return mt(false, t4, e4, n3, function(t5) {
                r3.push(t5);
              }), r3;
            }("mixed" === r2 ? this.type : r2, i2, e3);
          };
        }
        function Gt(t2, e2) {
          var n2 = e2.name, r2 = e2.type, i2 = e2.direction, o2 = n2.slice(0, -1) + "Entries";
          t2.prototype[o2] = function(t3) {
            if ("mixed" !== r2 && "mixed" !== this.type && r2 !== this.type) return O.empty();
            t3 = "" + t3;
            var e3 = this._nodes.get(t3);
            if (void 0 === e3) throw new F("Graph.".concat(o2, ': could not find the "').concat(t3, '" node in the graph.'));
            return function(t4, e4, n3) {
              if ("mixed" !== t4) {
                if ("undirected" === t4) return kt(null, n3, n3.undirected);
                if ("string" == typeof e4) return kt(null, n3, n3[e4]);
              }
              var r3 = O.empty(), i3 = new vt();
              return "undirected" !== t4 && ("out" !== e4 && (r3 = tt(r3, kt(i3, n3, n3.in))), "in" !== e4 && (r3 = tt(r3, kt(i3, n3, n3.out)))), "directed" !== t4 && (r3 = tt(r3, kt(i3, n3, n3.undirected))), r3;
            }("mixed" === r2 ? this.type : r2, i2, e3);
          };
        }
        function xt(t2, e2, n2, r2, i2) {
          for (var o2, a2, c2, u2, d2, s2, h2, p2 = r2._nodes.values(), f2 = r2.type; true !== (o2 = p2.next()).done; ) {
            var l2 = false;
            if (a2 = o2.value, "undirected" !== f2) for (c2 in u2 = a2.out) {
              d2 = u2[c2];
              do {
                if (s2 = d2.target, l2 = true, h2 = i2(a2.key, s2.key, a2.attributes, s2.attributes, d2.key, d2.attributes, d2.undirected), t2 && h2) return d2;
                d2 = d2.next;
              } while (d2);
            }
            if ("directed" !== f2) {
              for (c2 in u2 = a2.undirected) if (!(e2 && a2.key > c2)) {
                d2 = u2[c2];
                do {
                  if ((s2 = d2.target).key !== c2 && (s2 = d2.source), l2 = true, h2 = i2(a2.key, s2.key, a2.attributes, s2.attributes, d2.key, d2.attributes, d2.undirected), t2 && h2) return d2;
                  d2 = d2.next;
                } while (d2);
              }
            }
            if (n2 && !l2 && (h2 = i2(a2.key, null, a2.attributes, null, null, null, null), t2 && h2)) return null;
          }
        }
        function Et(t2) {
          if (!s(t2)) throw new B('Graph.import: invalid serialized node. A serialized node should be a plain object with at least a "key" property.');
          if (!("key" in t2)) throw new B("Graph.import: serialized node is missing its key.");
          if ("attributes" in t2 && (!s(t2.attributes) || null === t2.attributes)) throw new B("Graph.import: invalid attributes. Attributes should be a plain object, null or omitted.");
        }
        function At(t2) {
          if (!s(t2)) throw new B('Graph.import: invalid serialized edge. A serialized edge should be a plain object with at least a "source" & "target" property.');
          if (!("source" in t2)) throw new B("Graph.import: serialized edge is missing its source.");
          if (!("target" in t2)) throw new B("Graph.import: serialized edge is missing its target.");
          if ("attributes" in t2 && (!s(t2.attributes) || null === t2.attributes)) throw new B("Graph.import: invalid attributes. Attributes should be a plain object, null or omitted.");
          if ("undirected" in t2 && "boolean" != typeof t2.undirected) throw new B("Graph.import: invalid undirectedness information. Undirected should be boolean or omitted.");
        }
        vt.prototype.wrap = function(t2) {
          null === this.A ? this.A = t2 : null === this.B && (this.B = t2);
        }, vt.prototype.has = function(t2) {
          return null !== this.A && t2 in this.A || null !== this.B && t2 in this.B;
        };
        var Lt, St = (Lt = 255 & Math.floor(256 * Math.random()), function() {
          return Lt++;
        }), Dt = /* @__PURE__ */ new Set(["directed", "undirected", "mixed"]), Ut = /* @__PURE__ */ new Set(["domain", "_events", "_eventsCount", "_maxListeners"]), Nt = { allowSelfLoops: true, multi: false, type: "mixed" };
        function Ot(t2, e2, n2) {
          var r2 = new t2.NodeDataClass(e2, n2);
          return t2._nodes.set(e2, r2), t2.emit("nodeAdded", { key: e2, attributes: n2 }), r2;
        }
        function jt(t2, e2, n2, r2, i2, o2, a2, c2) {
          if (!r2 && "undirected" === t2.type) throw new I("Graph.".concat(e2, ": you cannot add a directed edge to an undirected graph. Use the #.addEdge or #.addUndirectedEdge instead."));
          if (r2 && "directed" === t2.type) throw new I("Graph.".concat(e2, ": you cannot add an undirected edge to a directed graph. Use the #.addEdge or #.addDirectedEdge instead."));
          if (c2 && !s(c2)) throw new B("Graph.".concat(e2, ': invalid attributes. Expecting an object but got "').concat(c2, '"'));
          if (o2 = "" + o2, a2 = "" + a2, c2 = c2 || {}, !t2.allowSelfLoops && o2 === a2) throw new I("Graph.".concat(e2, ': source & target are the same ("').concat(o2, `"), thus creating a loop explicitly forbidden by this graph 'allowSelfLoops' option set to false.`));
          var u2 = t2._nodes.get(o2), d2 = t2._nodes.get(a2);
          if (!u2) throw new F("Graph.".concat(e2, ': source node "').concat(o2, '" not found.'));
          if (!d2) throw new F("Graph.".concat(e2, ': target node "').concat(a2, '" not found.'));
          var h2 = { key: null, undirected: r2, source: o2, target: a2, attributes: c2 };
          if (n2) i2 = t2._edgeKeyGenerator();
          else if (i2 = "" + i2, t2._edges.has(i2)) throw new I("Graph.".concat(e2, ': the "').concat(i2, '" edge already exists in the graph.'));
          if (!t2.multi && (r2 ? void 0 !== u2.undirected[a2] : void 0 !== u2.out[a2])) throw new I("Graph.".concat(e2, ': an edge linking "').concat(o2, '" to "').concat(a2, `" already exists. If you really want to add multiple edges linking those nodes, you should create a multi graph by using the 'multi' option.`));
          var p2 = new V(r2, i2, u2, d2, c2);
          t2._edges.set(i2, p2);
          var f2 = o2 === a2;
          return r2 ? (u2.undirectedDegree++, d2.undirectedDegree++, f2 && (u2.undirectedLoops++, t2._undirectedSelfLoopCount++)) : (u2.outDegree++, d2.inDegree++, f2 && (u2.directedLoops++, t2._directedSelfLoopCount++)), t2.multi ? p2.attachMulti() : p2.attach(), r2 ? t2._undirectedSize++ : t2._directedSize++, h2.key = i2, t2.emit("edgeAdded", h2), i2;
        }
        function Ct(t2, e2, n2, r2, i2, o2, a2, c2, d2) {
          if (!r2 && "undirected" === t2.type) throw new I("Graph.".concat(e2, ": you cannot merge/update a directed edge to an undirected graph. Use the #.mergeEdge/#.updateEdge or #.addUndirectedEdge instead."));
          if (r2 && "directed" === t2.type) throw new I("Graph.".concat(e2, ": you cannot merge/update an undirected edge to a directed graph. Use the #.mergeEdge/#.updateEdge or #.addDirectedEdge instead."));
          if (c2) {
            if (d2) {
              if ("function" != typeof c2) throw new B("Graph.".concat(e2, ': invalid updater function. Expecting a function but got "').concat(c2, '"'));
            } else if (!s(c2)) throw new B("Graph.".concat(e2, ': invalid attributes. Expecting an object but got "').concat(c2, '"'));
          }
          var h2;
          if (o2 = "" + o2, a2 = "" + a2, d2 && (h2 = c2, c2 = void 0), !t2.allowSelfLoops && o2 === a2) throw new I("Graph.".concat(e2, ': source & target are the same ("').concat(o2, `"), thus creating a loop explicitly forbidden by this graph 'allowSelfLoops' option set to false.`));
          var p2, f2, l2 = t2._nodes.get(o2), g2 = t2._nodes.get(a2);
          if (!n2 && (p2 = t2._edges.get(i2))) {
            if (!(p2.source.key === o2 && p2.target.key === a2 || r2 && p2.source.key === a2 && p2.target.key === o2)) throw new I("Graph.".concat(e2, ': inconsistency detected when attempting to merge the "').concat(i2, '" edge with "').concat(o2, '" source & "').concat(a2, '" target vs. ("').concat(p2.source.key, '", "').concat(p2.target.key, '").'));
            f2 = p2;
          }
          if (f2 || t2.multi || !l2 || (f2 = r2 ? l2.undirected[a2] : l2.out[a2]), f2) {
            var y2 = [f2.key, false, false, false];
            if (d2 ? !h2 : !c2) return y2;
            if (d2) {
              var w2 = f2.attributes;
              f2.attributes = h2(w2), t2.emit("edgeAttributesUpdated", { type: "replace", key: f2.key, attributes: f2.attributes });
            } else u(f2.attributes, c2), t2.emit("edgeAttributesUpdated", { type: "merge", key: f2.key, attributes: f2.attributes, data: c2 });
            return y2;
          }
          c2 = c2 || {}, d2 && h2 && (c2 = h2(c2));
          var v2 = { key: null, undirected: r2, source: o2, target: a2, attributes: c2 };
          if (n2) i2 = t2._edgeKeyGenerator();
          else if (i2 = "" + i2, t2._edges.has(i2)) throw new I("Graph.".concat(e2, ': the "').concat(i2, '" edge already exists in the graph.'));
          var b2 = false, m2 = false;
          l2 || (l2 = Ot(t2, o2, {}), b2 = true, o2 === a2 && (g2 = l2, m2 = true)), g2 || (g2 = Ot(t2, a2, {}), m2 = true), p2 = new V(r2, i2, l2, g2, c2), t2._edges.set(i2, p2);
          var k2 = o2 === a2;
          return r2 ? (l2.undirectedDegree++, g2.undirectedDegree++, k2 && (l2.undirectedLoops++, t2._undirectedSelfLoopCount++)) : (l2.outDegree++, g2.inDegree++, k2 && (l2.directedLoops++, t2._directedSelfLoopCount++)), t2.multi ? p2.attachMulti() : p2.attach(), r2 ? t2._undirectedSize++ : t2._directedSize++, v2.key = i2, t2.emit("edgeAdded", v2), [i2, true, b2, m2];
        }
        function Mt(t2, e2) {
          t2._edges.delete(e2.key);
          var n2 = e2.source, r2 = e2.target, i2 = e2.attributes, o2 = e2.undirected, a2 = n2 === r2;
          o2 ? (n2.undirectedDegree--, r2.undirectedDegree--, a2 && (n2.undirectedLoops--, t2._undirectedSelfLoopCount--)) : (n2.outDegree--, r2.inDegree--, a2 && (n2.directedLoops--, t2._directedSelfLoopCount--)), t2.multi ? e2.detachMulti() : e2.detach(), o2 ? t2._undirectedSize-- : t2._directedSize--, t2.emit("edgeDropped", { key: e2.key, attributes: i2, source: n2.key, target: r2.key, undirected: o2 });
        }
        var zt = function(n2) {
          function r2(t2) {
            var e2;
            if (e2 = n2.call(this) || this, "boolean" != typeof (t2 = u({}, Nt, t2)).multi) throw new B(`Graph.constructor: invalid 'multi' option. Expecting a boolean but got "`.concat(t2.multi, '".'));
            if (!Dt.has(t2.type)) throw new B(`Graph.constructor: invalid 'type' option. Should be one of "mixed", "directed" or "undirected" but got "`.concat(t2.type, '".'));
            if ("boolean" != typeof t2.allowSelfLoops) throw new B(`Graph.constructor: invalid 'allowSelfLoops' option. Expecting a boolean but got "`.concat(t2.allowSelfLoops, '".'));
            var r3 = "mixed" === t2.type ? Y : "directed" === t2.type ? q : J;
            p(c(e2), "NodeDataClass", r3);
            var i3 = "geid_" + St() + "_", o2 = 0;
            return p(c(e2), "_attributes", {}), p(c(e2), "_nodes", /* @__PURE__ */ new Map()), p(c(e2), "_edges", /* @__PURE__ */ new Map()), p(c(e2), "_directedSize", 0), p(c(e2), "_undirectedSize", 0), p(c(e2), "_directedSelfLoopCount", 0), p(c(e2), "_undirectedSelfLoopCount", 0), p(c(e2), "_edgeKeyGenerator", function() {
              var t3;
              do {
                t3 = i3 + o2++;
              } while (e2._edges.has(t3));
              return t3;
            }), p(c(e2), "_options", t2), Ut.forEach(function(t3) {
              return p(c(e2), t3, e2[t3]);
            }), f(c(e2), "order", function() {
              return e2._nodes.size;
            }), f(c(e2), "size", function() {
              return e2._edges.size;
            }), f(c(e2), "directedSize", function() {
              return e2._directedSize;
            }), f(c(e2), "undirectedSize", function() {
              return e2._undirectedSize;
            }), f(c(e2), "selfLoopCount", function() {
              return e2._directedSelfLoopCount + e2._undirectedSelfLoopCount;
            }), f(c(e2), "directedSelfLoopCount", function() {
              return e2._directedSelfLoopCount;
            }), f(c(e2), "undirectedSelfLoopCount", function() {
              return e2._undirectedSelfLoopCount;
            }), f(c(e2), "multi", e2._options.multi), f(c(e2), "type", e2._options.type), f(c(e2), "allowSelfLoops", e2._options.allowSelfLoops), f(c(e2), "implementation", function() {
              return "graphology";
            }), e2;
          }
          e(r2, n2);
          var i2 = r2.prototype;
          return i2._resetInstanceCounters = function() {
            this._directedSize = 0, this._undirectedSize = 0, this._directedSelfLoopCount = 0, this._undirectedSelfLoopCount = 0;
          }, i2.hasNode = function(t2) {
            return this._nodes.has("" + t2);
          }, i2.hasDirectedEdge = function(t2, e2) {
            if ("undirected" === this.type) return false;
            if (1 === arguments.length) {
              var n3 = "" + t2, r3 = this._edges.get(n3);
              return !!r3 && !r3.undirected;
            }
            if (2 === arguments.length) {
              t2 = "" + t2, e2 = "" + e2;
              var i3 = this._nodes.get(t2);
              return !!i3 && i3.out.hasOwnProperty(e2);
            }
            throw new B("Graph.hasDirectedEdge: invalid arity (".concat(arguments.length, ", instead of 1 or 2). You can either ask for an edge id or for the existence of an edge between a source & a target."));
          }, i2.hasUndirectedEdge = function(t2, e2) {
            if ("directed" === this.type) return false;
            if (1 === arguments.length) {
              var n3 = "" + t2, r3 = this._edges.get(n3);
              return !!r3 && r3.undirected;
            }
            if (2 === arguments.length) {
              t2 = "" + t2, e2 = "" + e2;
              var i3 = this._nodes.get(t2);
              return !!i3 && i3.undirected.hasOwnProperty(e2);
            }
            throw new B("Graph.hasDirectedEdge: invalid arity (".concat(arguments.length, ", instead of 1 or 2). You can either ask for an edge id or for the existence of an edge between a source & a target."));
          }, i2.hasEdge = function(t2, e2) {
            if (1 === arguments.length) {
              var n3 = "" + t2;
              return this._edges.has(n3);
            }
            if (2 === arguments.length) {
              t2 = "" + t2, e2 = "" + e2;
              var r3 = this._nodes.get(t2);
              return !!r3 && (void 0 !== r3.out && r3.out.hasOwnProperty(e2) || void 0 !== r3.undirected && r3.undirected.hasOwnProperty(e2));
            }
            throw new B("Graph.hasEdge: invalid arity (".concat(arguments.length, ", instead of 1 or 2). You can either ask for an edge id or for the existence of an edge between a source & a target."));
          }, i2.directedEdge = function(t2, e2) {
            if ("undirected" !== this.type) {
              if (t2 = "" + t2, e2 = "" + e2, this.multi) throw new I("Graph.directedEdge: this method is irrelevant with multigraphs since there might be multiple edges between source & target. See #.directedEdges instead.");
              var n3 = this._nodes.get(t2);
              if (!n3) throw new F('Graph.directedEdge: could not find the "'.concat(t2, '" source node in the graph.'));
              if (!this._nodes.has(e2)) throw new F('Graph.directedEdge: could not find the "'.concat(e2, '" target node in the graph.'));
              var r3 = n3.out && n3.out[e2] || void 0;
              return r3 ? r3.key : void 0;
            }
          }, i2.undirectedEdge = function(t2, e2) {
            if ("directed" !== this.type) {
              if (t2 = "" + t2, e2 = "" + e2, this.multi) throw new I("Graph.undirectedEdge: this method is irrelevant with multigraphs since there might be multiple edges between source & target. See #.undirectedEdges instead.");
              var n3 = this._nodes.get(t2);
              if (!n3) throw new F('Graph.undirectedEdge: could not find the "'.concat(t2, '" source node in the graph.'));
              if (!this._nodes.has(e2)) throw new F('Graph.undirectedEdge: could not find the "'.concat(e2, '" target node in the graph.'));
              var r3 = n3.undirected && n3.undirected[e2] || void 0;
              return r3 ? r3.key : void 0;
            }
          }, i2.edge = function(t2, e2) {
            if (this.multi) throw new I("Graph.edge: this method is irrelevant with multigraphs since there might be multiple edges between source & target. See #.edges instead.");
            t2 = "" + t2, e2 = "" + e2;
            var n3 = this._nodes.get(t2);
            if (!n3) throw new F('Graph.edge: could not find the "'.concat(t2, '" source node in the graph.'));
            if (!this._nodes.has(e2)) throw new F('Graph.edge: could not find the "'.concat(e2, '" target node in the graph.'));
            var r3 = n3.out && n3.out[e2] || n3.undirected && n3.undirected[e2] || void 0;
            if (r3) return r3.key;
          }, i2.areDirectedNeighbors = function(t2, e2) {
            t2 = "" + t2, e2 = "" + e2;
            var n3 = this._nodes.get(t2);
            if (!n3) throw new F('Graph.areDirectedNeighbors: could not find the "'.concat(t2, '" node in the graph.'));
            return "undirected" !== this.type && (e2 in n3.in || e2 in n3.out);
          }, i2.areOutNeighbors = function(t2, e2) {
            t2 = "" + t2, e2 = "" + e2;
            var n3 = this._nodes.get(t2);
            if (!n3) throw new F('Graph.areOutNeighbors: could not find the "'.concat(t2, '" node in the graph.'));
            return "undirected" !== this.type && e2 in n3.out;
          }, i2.areInNeighbors = function(t2, e2) {
            t2 = "" + t2, e2 = "" + e2;
            var n3 = this._nodes.get(t2);
            if (!n3) throw new F('Graph.areInNeighbors: could not find the "'.concat(t2, '" node in the graph.'));
            return "undirected" !== this.type && e2 in n3.in;
          }, i2.areUndirectedNeighbors = function(t2, e2) {
            t2 = "" + t2, e2 = "" + e2;
            var n3 = this._nodes.get(t2);
            if (!n3) throw new F('Graph.areUndirectedNeighbors: could not find the "'.concat(t2, '" node in the graph.'));
            return "directed" !== this.type && e2 in n3.undirected;
          }, i2.areNeighbors = function(t2, e2) {
            t2 = "" + t2, e2 = "" + e2;
            var n3 = this._nodes.get(t2);
            if (!n3) throw new F('Graph.areNeighbors: could not find the "'.concat(t2, '" node in the graph.'));
            return "undirected" !== this.type && (e2 in n3.in || e2 in n3.out) || "directed" !== this.type && e2 in n3.undirected;
          }, i2.areInboundNeighbors = function(t2, e2) {
            t2 = "" + t2, e2 = "" + e2;
            var n3 = this._nodes.get(t2);
            if (!n3) throw new F('Graph.areInboundNeighbors: could not find the "'.concat(t2, '" node in the graph.'));
            return "undirected" !== this.type && e2 in n3.in || "directed" !== this.type && e2 in n3.undirected;
          }, i2.areOutboundNeighbors = function(t2, e2) {
            t2 = "" + t2, e2 = "" + e2;
            var n3 = this._nodes.get(t2);
            if (!n3) throw new F('Graph.areOutboundNeighbors: could not find the "'.concat(t2, '" node in the graph.'));
            return "undirected" !== this.type && e2 in n3.out || "directed" !== this.type && e2 in n3.undirected;
          }, i2.inDegree = function(t2) {
            t2 = "" + t2;
            var e2 = this._nodes.get(t2);
            if (!e2) throw new F('Graph.inDegree: could not find the "'.concat(t2, '" node in the graph.'));
            return "undirected" === this.type ? 0 : e2.inDegree;
          }, i2.outDegree = function(t2) {
            t2 = "" + t2;
            var e2 = this._nodes.get(t2);
            if (!e2) throw new F('Graph.outDegree: could not find the "'.concat(t2, '" node in the graph.'));
            return "undirected" === this.type ? 0 : e2.outDegree;
          }, i2.directedDegree = function(t2) {
            t2 = "" + t2;
            var e2 = this._nodes.get(t2);
            if (!e2) throw new F('Graph.directedDegree: could not find the "'.concat(t2, '" node in the graph.'));
            return "undirected" === this.type ? 0 : e2.inDegree + e2.outDegree;
          }, i2.undirectedDegree = function(t2) {
            t2 = "" + t2;
            var e2 = this._nodes.get(t2);
            if (!e2) throw new F('Graph.undirectedDegree: could not find the "'.concat(t2, '" node in the graph.'));
            return "directed" === this.type ? 0 : e2.undirectedDegree;
          }, i2.inboundDegree = function(t2) {
            t2 = "" + t2;
            var e2 = this._nodes.get(t2);
            if (!e2) throw new F('Graph.inboundDegree: could not find the "'.concat(t2, '" node in the graph.'));
            var n3 = 0;
            return "directed" !== this.type && (n3 += e2.undirectedDegree), "undirected" !== this.type && (n3 += e2.inDegree), n3;
          }, i2.outboundDegree = function(t2) {
            t2 = "" + t2;
            var e2 = this._nodes.get(t2);
            if (!e2) throw new F('Graph.outboundDegree: could not find the "'.concat(t2, '" node in the graph.'));
            var n3 = 0;
            return "directed" !== this.type && (n3 += e2.undirectedDegree), "undirected" !== this.type && (n3 += e2.outDegree), n3;
          }, i2.degree = function(t2) {
            t2 = "" + t2;
            var e2 = this._nodes.get(t2);
            if (!e2) throw new F('Graph.degree: could not find the "'.concat(t2, '" node in the graph.'));
            var n3 = 0;
            return "directed" !== this.type && (n3 += e2.undirectedDegree), "undirected" !== this.type && (n3 += e2.inDegree + e2.outDegree), n3;
          }, i2.inDegreeWithoutSelfLoops = function(t2) {
            t2 = "" + t2;
            var e2 = this._nodes.get(t2);
            if (!e2) throw new F('Graph.inDegreeWithoutSelfLoops: could not find the "'.concat(t2, '" node in the graph.'));
            return "undirected" === this.type ? 0 : e2.inDegree - e2.directedLoops;
          }, i2.outDegreeWithoutSelfLoops = function(t2) {
            t2 = "" + t2;
            var e2 = this._nodes.get(t2);
            if (!e2) throw new F('Graph.outDegreeWithoutSelfLoops: could not find the "'.concat(t2, '" node in the graph.'));
            return "undirected" === this.type ? 0 : e2.outDegree - e2.directedLoops;
          }, i2.directedDegreeWithoutSelfLoops = function(t2) {
            t2 = "" + t2;
            var e2 = this._nodes.get(t2);
            if (!e2) throw new F('Graph.directedDegreeWithoutSelfLoops: could not find the "'.concat(t2, '" node in the graph.'));
            return "undirected" === this.type ? 0 : e2.inDegree + e2.outDegree - 2 * e2.directedLoops;
          }, i2.undirectedDegreeWithoutSelfLoops = function(t2) {
            t2 = "" + t2;
            var e2 = this._nodes.get(t2);
            if (!e2) throw new F('Graph.undirectedDegreeWithoutSelfLoops: could not find the "'.concat(t2, '" node in the graph.'));
            return "directed" === this.type ? 0 : e2.undirectedDegree - 2 * e2.undirectedLoops;
          }, i2.inboundDegreeWithoutSelfLoops = function(t2) {
            t2 = "" + t2;
            var e2 = this._nodes.get(t2);
            if (!e2) throw new F('Graph.inboundDegreeWithoutSelfLoops: could not find the "'.concat(t2, '" node in the graph.'));
            var n3 = 0, r3 = 0;
            return "directed" !== this.type && (n3 += e2.undirectedDegree, r3 += 2 * e2.undirectedLoops), "undirected" !== this.type && (n3 += e2.inDegree, r3 += e2.directedLoops), n3 - r3;
          }, i2.outboundDegreeWithoutSelfLoops = function(t2) {
            t2 = "" + t2;
            var e2 = this._nodes.get(t2);
            if (!e2) throw new F('Graph.outboundDegreeWithoutSelfLoops: could not find the "'.concat(t2, '" node in the graph.'));
            var n3 = 0, r3 = 0;
            return "directed" !== this.type && (n3 += e2.undirectedDegree, r3 += 2 * e2.undirectedLoops), "undirected" !== this.type && (n3 += e2.outDegree, r3 += e2.directedLoops), n3 - r3;
          }, i2.degreeWithoutSelfLoops = function(t2) {
            t2 = "" + t2;
            var e2 = this._nodes.get(t2);
            if (!e2) throw new F('Graph.degreeWithoutSelfLoops: could not find the "'.concat(t2, '" node in the graph.'));
            var n3 = 0, r3 = 0;
            return "directed" !== this.type && (n3 += e2.undirectedDegree, r3 += 2 * e2.undirectedLoops), "undirected" !== this.type && (n3 += e2.inDegree + e2.outDegree, r3 += 2 * e2.directedLoops), n3 - r3;
          }, i2.source = function(t2) {
            t2 = "" + t2;
            var e2 = this._edges.get(t2);
            if (!e2) throw new F('Graph.source: could not find the "'.concat(t2, '" edge in the graph.'));
            return e2.source.key;
          }, i2.target = function(t2) {
            t2 = "" + t2;
            var e2 = this._edges.get(t2);
            if (!e2) throw new F('Graph.target: could not find the "'.concat(t2, '" edge in the graph.'));
            return e2.target.key;
          }, i2.extremities = function(t2) {
            t2 = "" + t2;
            var e2 = this._edges.get(t2);
            if (!e2) throw new F('Graph.extremities: could not find the "'.concat(t2, '" edge in the graph.'));
            return [e2.source.key, e2.target.key];
          }, i2.opposite = function(t2, e2) {
            t2 = "" + t2, e2 = "" + e2;
            var n3 = this._edges.get(e2);
            if (!n3) throw new F('Graph.opposite: could not find the "'.concat(e2, '" edge in the graph.'));
            var r3 = n3.source.key, i3 = n3.target.key;
            if (t2 === r3) return i3;
            if (t2 === i3) return r3;
            throw new F('Graph.opposite: the "'.concat(t2, '" node is not attached to the "').concat(e2, '" edge (').concat(r3, ", ").concat(i3, ")."));
          }, i2.hasExtremity = function(t2, e2) {
            t2 = "" + t2, e2 = "" + e2;
            var n3 = this._edges.get(t2);
            if (!n3) throw new F('Graph.hasExtremity: could not find the "'.concat(t2, '" edge in the graph.'));
            return n3.source.key === e2 || n3.target.key === e2;
          }, i2.isUndirected = function(t2) {
            t2 = "" + t2;
            var e2 = this._edges.get(t2);
            if (!e2) throw new F('Graph.isUndirected: could not find the "'.concat(t2, '" edge in the graph.'));
            return e2.undirected;
          }, i2.isDirected = function(t2) {
            t2 = "" + t2;
            var e2 = this._edges.get(t2);
            if (!e2) throw new F('Graph.isDirected: could not find the "'.concat(t2, '" edge in the graph.'));
            return !e2.undirected;
          }, i2.isSelfLoop = function(t2) {
            t2 = "" + t2;
            var e2 = this._edges.get(t2);
            if (!e2) throw new F('Graph.isSelfLoop: could not find the "'.concat(t2, '" edge in the graph.'));
            return e2.source === e2.target;
          }, i2.addNode = function(t2, e2) {
            var n3 = function(t3, e3, n4) {
              if (n4 && !s(n4)) throw new B('Graph.addNode: invalid attributes. Expecting an object but got "'.concat(n4, '"'));
              if (e3 = "" + e3, n4 = n4 || {}, t3._nodes.has(e3)) throw new I('Graph.addNode: the "'.concat(e3, '" node already exist in the graph.'));
              var r3 = new t3.NodeDataClass(e3, n4);
              return t3._nodes.set(e3, r3), t3.emit("nodeAdded", { key: e3, attributes: n4 }), r3;
            }(this, t2, e2);
            return n3.key;
          }, i2.mergeNode = function(t2, e2) {
            if (e2 && !s(e2)) throw new B('Graph.mergeNode: invalid attributes. Expecting an object but got "'.concat(e2, '"'));
            t2 = "" + t2, e2 = e2 || {};
            var n3 = this._nodes.get(t2);
            return n3 ? (e2 && (u(n3.attributes, e2), this.emit("nodeAttributesUpdated", { type: "merge", key: t2, attributes: n3.attributes, data: e2 })), [t2, false]) : (n3 = new this.NodeDataClass(t2, e2), this._nodes.set(t2, n3), this.emit("nodeAdded", { key: t2, attributes: e2 }), [t2, true]);
          }, i2.updateNode = function(t2, e2) {
            if (e2 && "function" != typeof e2) throw new B('Graph.updateNode: invalid updater function. Expecting a function but got "'.concat(e2, '"'));
            t2 = "" + t2;
            var n3 = this._nodes.get(t2);
            if (n3) {
              if (e2) {
                var r3 = n3.attributes;
                n3.attributes = e2(r3), this.emit("nodeAttributesUpdated", { type: "replace", key: t2, attributes: n3.attributes });
              }
              return [t2, false];
            }
            var i3 = e2 ? e2({}) : {};
            return n3 = new this.NodeDataClass(t2, i3), this._nodes.set(t2, n3), this.emit("nodeAdded", { key: t2, attributes: i3 }), [t2, true];
          }, i2.dropNode = function(t2) {
            t2 = "" + t2;
            var e2, n3 = this._nodes.get(t2);
            if (!n3) throw new F('Graph.dropNode: could not find the "'.concat(t2, '" node in the graph.'));
            if ("undirected" !== this.type) {
              for (var r3 in n3.out) {
                e2 = n3.out[r3];
                do {
                  Mt(this, e2), e2 = e2.next;
                } while (e2);
              }
              for (var i3 in n3.in) {
                e2 = n3.in[i3];
                do {
                  Mt(this, e2), e2 = e2.next;
                } while (e2);
              }
            }
            if ("directed" !== this.type) for (var o2 in n3.undirected) {
              e2 = n3.undirected[o2];
              do {
                Mt(this, e2), e2 = e2.next;
              } while (e2);
            }
            this._nodes.delete(t2), this.emit("nodeDropped", { key: t2, attributes: n3.attributes });
          }, i2.dropEdge = function(t2) {
            var e2;
            if (arguments.length > 1) {
              var n3 = "" + arguments[0], r3 = "" + arguments[1];
              if (!(e2 = d(this, n3, r3, this.type))) throw new F('Graph.dropEdge: could not find the "'.concat(n3, '" -> "').concat(r3, '" edge in the graph.'));
            } else if (t2 = "" + t2, !(e2 = this._edges.get(t2))) throw new F('Graph.dropEdge: could not find the "'.concat(t2, '" edge in the graph.'));
            return Mt(this, e2), this;
          }, i2.dropDirectedEdge = function(t2, e2) {
            if (arguments.length < 2) throw new I("Graph.dropDirectedEdge: it does not make sense to try and drop a directed edge by key. What if the edge with this key is undirected? Use #.dropEdge for this purpose instead.");
            if (this.multi) throw new I("Graph.dropDirectedEdge: cannot use a {source,target} combo when dropping an edge in a MultiGraph since we cannot infer the one you want to delete as there could be multiple ones.");
            var n3 = d(this, t2 = "" + t2, e2 = "" + e2, "directed");
            if (!n3) throw new F('Graph.dropDirectedEdge: could not find a "'.concat(t2, '" -> "').concat(e2, '" edge in the graph.'));
            return Mt(this, n3), this;
          }, i2.dropUndirectedEdge = function(t2, e2) {
            if (arguments.length < 2) throw new I("Graph.dropUndirectedEdge: it does not make sense to drop a directed edge by key. What if the edge with this key is undirected? Use #.dropEdge for this purpose instead.");
            if (this.multi) throw new I("Graph.dropUndirectedEdge: cannot use a {source,target} combo when dropping an edge in a MultiGraph since we cannot infer the one you want to delete as there could be multiple ones.");
            var n3 = d(this, t2, e2, "undirected");
            if (!n3) throw new F('Graph.dropUndirectedEdge: could not find a "'.concat(t2, '" -> "').concat(e2, '" edge in the graph.'));
            return Mt(this, n3), this;
          }, i2.clear = function() {
            this._edges.clear(), this._nodes.clear(), this._resetInstanceCounters(), this.emit("cleared");
          }, i2.clearEdges = function() {
            for (var t2, e2 = this._nodes.values(); true !== (t2 = e2.next()).done; ) t2.value.clear();
            this._edges.clear(), this._resetInstanceCounters(), this.emit("edgesCleared");
          }, i2.getAttribute = function(t2) {
            return this._attributes[t2];
          }, i2.getAttributes = function() {
            return this._attributes;
          }, i2.hasAttribute = function(t2) {
            return this._attributes.hasOwnProperty(t2);
          }, i2.setAttribute = function(t2, e2) {
            return this._attributes[t2] = e2, this.emit("attributesUpdated", { type: "set", attributes: this._attributes, name: t2 }), this;
          }, i2.updateAttribute = function(t2, e2) {
            if ("function" != typeof e2) throw new B("Graph.updateAttribute: updater should be a function.");
            var n3 = this._attributes[t2];
            return this._attributes[t2] = e2(n3), this.emit("attributesUpdated", { type: "set", attributes: this._attributes, name: t2 }), this;
          }, i2.removeAttribute = function(t2) {
            return delete this._attributes[t2], this.emit("attributesUpdated", { type: "remove", attributes: this._attributes, name: t2 }), this;
          }, i2.replaceAttributes = function(t2) {
            if (!s(t2)) throw new B("Graph.replaceAttributes: provided attributes are not a plain object.");
            return this._attributes = t2, this.emit("attributesUpdated", { type: "replace", attributes: this._attributes }), this;
          }, i2.mergeAttributes = function(t2) {
            if (!s(t2)) throw new B("Graph.mergeAttributes: provided attributes are not a plain object.");
            return u(this._attributes, t2), this.emit("attributesUpdated", { type: "merge", attributes: this._attributes, data: t2 }), this;
          }, i2.updateAttributes = function(t2) {
            if ("function" != typeof t2) throw new B("Graph.updateAttributes: provided updater is not a function.");
            return this._attributes = t2(this._attributes), this.emit("attributesUpdated", { type: "update", attributes: this._attributes }), this;
          }, i2.updateEachNodeAttributes = function(t2, e2) {
            if ("function" != typeof t2) throw new B("Graph.updateEachNodeAttributes: expecting an updater function.");
            if (e2 && !l(e2)) throw new B("Graph.updateEachNodeAttributes: invalid hints. Expecting an object having the following shape: {attributes?: [string]}");
            for (var n3, r3, i3 = this._nodes.values(); true !== (n3 = i3.next()).done; ) (r3 = n3.value).attributes = t2(r3.key, r3.attributes);
            this.emit("eachNodeAttributesUpdated", { hints: e2 || null });
          }, i2.updateEachEdgeAttributes = function(t2, e2) {
            if ("function" != typeof t2) throw new B("Graph.updateEachEdgeAttributes: expecting an updater function.");
            if (e2 && !l(e2)) throw new B("Graph.updateEachEdgeAttributes: invalid hints. Expecting an object having the following shape: {attributes?: [string]}");
            for (var n3, r3, i3, o2, a2 = this._edges.values(); true !== (n3 = a2.next()).done; ) i3 = (r3 = n3.value).source, o2 = r3.target, r3.attributes = t2(r3.key, r3.attributes, i3.key, o2.key, i3.attributes, o2.attributes, r3.undirected);
            this.emit("eachEdgeAttributesUpdated", { hints: e2 || null });
          }, i2.forEachAdjacencyEntry = function(t2) {
            if ("function" != typeof t2) throw new B("Graph.forEachAdjacencyEntry: expecting a callback.");
            xt(false, false, false, this, t2);
          }, i2.forEachAdjacencyEntryWithOrphans = function(t2) {
            if ("function" != typeof t2) throw new B("Graph.forEachAdjacencyEntryWithOrphans: expecting a callback.");
            xt(false, false, true, this, t2);
          }, i2.forEachAssymetricAdjacencyEntry = function(t2) {
            if ("function" != typeof t2) throw new B("Graph.forEachAssymetricAdjacencyEntry: expecting a callback.");
            xt(false, true, false, this, t2);
          }, i2.forEachAssymetricAdjacencyEntryWithOrphans = function(t2) {
            if ("function" != typeof t2) throw new B("Graph.forEachAssymetricAdjacencyEntryWithOrphans: expecting a callback.");
            xt(false, true, true, this, t2);
          }, i2.nodes = function() {
            return "function" == typeof Array.from ? Array.from(this._nodes.keys()) : K(this._nodes.keys(), this._nodes.size);
          }, i2.forEachNode = function(t2) {
            if ("function" != typeof t2) throw new B("Graph.forEachNode: expecting a callback.");
            for (var e2, n3, r3 = this._nodes.values(); true !== (e2 = r3.next()).done; ) t2((n3 = e2.value).key, n3.attributes);
          }, i2.findNode = function(t2) {
            if ("function" != typeof t2) throw new B("Graph.findNode: expecting a callback.");
            for (var e2, n3, r3 = this._nodes.values(); true !== (e2 = r3.next()).done; ) if (t2((n3 = e2.value).key, n3.attributes)) return n3.key;
          }, i2.mapNodes = function(t2) {
            if ("function" != typeof t2) throw new B("Graph.mapNode: expecting a callback.");
            for (var e2, n3, r3 = this._nodes.values(), i3 = new Array(this.order), o2 = 0; true !== (e2 = r3.next()).done; ) n3 = e2.value, i3[o2++] = t2(n3.key, n3.attributes);
            return i3;
          }, i2.someNode = function(t2) {
            if ("function" != typeof t2) throw new B("Graph.someNode: expecting a callback.");
            for (var e2, n3, r3 = this._nodes.values(); true !== (e2 = r3.next()).done; ) if (t2((n3 = e2.value).key, n3.attributes)) return true;
            return false;
          }, i2.everyNode = function(t2) {
            if ("function" != typeof t2) throw new B("Graph.everyNode: expecting a callback.");
            for (var e2, n3, r3 = this._nodes.values(); true !== (e2 = r3.next()).done; ) if (!t2((n3 = e2.value).key, n3.attributes)) return false;
            return true;
          }, i2.filterNodes = function(t2) {
            if ("function" != typeof t2) throw new B("Graph.filterNodes: expecting a callback.");
            for (var e2, n3, r3 = this._nodes.values(), i3 = []; true !== (e2 = r3.next()).done; ) t2((n3 = e2.value).key, n3.attributes) && i3.push(n3.key);
            return i3;
          }, i2.reduceNodes = function(t2, e2) {
            if ("function" != typeof t2) throw new B("Graph.reduceNodes: expecting a callback.");
            if (arguments.length < 2) throw new B("Graph.reduceNodes: missing initial value. You must provide it because the callback takes more than one argument and we cannot infer the initial value from the first iteration, as you could with a simple array.");
            for (var n3, r3, i3 = e2, o2 = this._nodes.values(); true !== (n3 = o2.next()).done; ) i3 = t2(i3, (r3 = n3.value).key, r3.attributes);
            return i3;
          }, i2.nodeEntries = function() {
            var t2 = this._nodes.values();
            return new O(function() {
              var e2 = t2.next();
              if (e2.done) return e2;
              var n3 = e2.value;
              return { value: { node: n3.key, attributes: n3.attributes }, done: false };
            });
          }, i2.export = function() {
            var t2 = this, e2 = new Array(this._nodes.size), n3 = 0;
            this._nodes.forEach(function(t3, r4) {
              e2[n3++] = function(t4, e3) {
                var n4 = { key: t4 };
                return h(e3.attributes) || (n4.attributes = u({}, e3.attributes)), n4;
              }(r4, t3);
            });
            var r3 = new Array(this._edges.size);
            return n3 = 0, this._edges.forEach(function(e3, i3) {
              r3[n3++] = function(t3, e4, n4) {
                var r4 = { key: e4, source: n4.source.key, target: n4.target.key };
                return h(n4.attributes) || (r4.attributes = u({}, n4.attributes)), "mixed" === t3 && n4.undirected && (r4.undirected = true), r4;
              }(t2.type, i3, e3);
            }), { options: { type: this.type, multi: this.multi, allowSelfLoops: this.allowSelfLoops }, attributes: this.getAttributes(), nodes: e2, edges: r3 };
          }, i2.import = function(t2) {
            var e2, n3, i3, o2, a2, c2 = this, u2 = arguments.length > 1 && void 0 !== arguments[1] && arguments[1];
            if (t2 instanceof r2) return t2.forEachNode(function(t3, e3) {
              u2 ? c2.mergeNode(t3, e3) : c2.addNode(t3, e3);
            }), t2.forEachEdge(function(t3, e3, n4, r3, i4, o3, a3) {
              u2 ? a3 ? c2.mergeUndirectedEdgeWithKey(t3, n4, r3, e3) : c2.mergeDirectedEdgeWithKey(t3, n4, r3, e3) : a3 ? c2.addUndirectedEdgeWithKey(t3, n4, r3, e3) : c2.addDirectedEdgeWithKey(t3, n4, r3, e3);
            }), this;
            if (!s(t2)) throw new B("Graph.import: invalid argument. Expecting a serialized graph or, alternatively, a Graph instance.");
            if (t2.attributes) {
              if (!s(t2.attributes)) throw new B("Graph.import: invalid attributes. Expecting a plain object.");
              u2 ? this.mergeAttributes(t2.attributes) : this.replaceAttributes(t2.attributes);
            }
            if (t2.nodes) {
              if (i3 = t2.nodes, !Array.isArray(i3)) throw new B("Graph.import: invalid nodes. Expecting an array.");
              for (e2 = 0, n3 = i3.length; e2 < n3; e2++) {
                Et(o2 = i3[e2]);
                var d2 = o2, h2 = d2.key, p2 = d2.attributes;
                u2 ? this.mergeNode(h2, p2) : this.addNode(h2, p2);
              }
            }
            if (t2.edges) {
              var f2 = false;
              if ("undirected" === this.type && (f2 = true), i3 = t2.edges, !Array.isArray(i3)) throw new B("Graph.import: invalid edges. Expecting an array.");
              for (e2 = 0, n3 = i3.length; e2 < n3; e2++) {
                At(a2 = i3[e2]);
                var l2 = a2, g2 = l2.source, y2 = l2.target, w2 = l2.attributes, v2 = l2.undirected, b2 = void 0 === v2 ? f2 : v2;
                "key" in a2 ? (u2 ? b2 ? this.mergeUndirectedEdgeWithKey : this.mergeDirectedEdgeWithKey : b2 ? this.addUndirectedEdgeWithKey : this.addDirectedEdgeWithKey).call(this, a2.key, g2, y2, w2) : (u2 ? b2 ? this.mergeUndirectedEdge : this.mergeDirectedEdge : b2 ? this.addUndirectedEdge : this.addDirectedEdge).call(this, g2, y2, w2);
              }
            }
            return this;
          }, i2.nullCopy = function(t2) {
            var e2 = new r2(u({}, this._options, t2));
            return e2.replaceAttributes(u({}, this.getAttributes())), e2;
          }, i2.emptyCopy = function(t2) {
            var e2 = this.nullCopy(t2);
            return this._nodes.forEach(function(t3, n3) {
              var r3 = u({}, t3.attributes);
              t3 = new e2.NodeDataClass(n3, r3), e2._nodes.set(n3, t3);
            }), e2;
          }, i2.copy = function(t2) {
            if ("string" == typeof (t2 = t2 || {}).type && t2.type !== this.type && "mixed" !== t2.type) throw new I('Graph.copy: cannot create an incompatible copy from "'.concat(this.type, '" type to "').concat(t2.type, '" because this would mean losing information about the current graph.'));
            if ("boolean" == typeof t2.multi && t2.multi !== this.multi && true !== t2.multi) throw new I("Graph.copy: cannot create an incompatible copy by downgrading a multi graph to a simple one because this would mean losing information about the current graph.");
            if ("boolean" == typeof t2.allowSelfLoops && t2.allowSelfLoops !== this.allowSelfLoops && true !== t2.allowSelfLoops) throw new I("Graph.copy: cannot create an incompatible copy from a graph allowing self loops to one that does not because this would mean losing information about the current graph.");
            for (var e2, n3, r3 = this.emptyCopy(t2), i3 = this._edges.values(); true !== (e2 = i3.next()).done; ) jt(r3, "copy", false, (n3 = e2.value).undirected, n3.key, n3.source.key, n3.target.key, u({}, n3.attributes));
            return r3;
          }, i2.toJSON = function() {
            return this.export();
          }, i2.toString = function() {
            return "[object Graph]";
          }, i2.inspect = function() {
            var e2 = this, n3 = {};
            this._nodes.forEach(function(t2, e3) {
              n3[e3] = t2.attributes;
            });
            var r3 = {}, i3 = {};
            this._edges.forEach(function(t2, n4) {
              var o3, a3 = t2.undirected ? "--" : "->", c2 = "", u2 = t2.source.key, d2 = t2.target.key;
              t2.undirected && u2 > d2 && (o3 = u2, u2 = d2, d2 = o3);
              var s2 = "(".concat(u2, ")").concat(a3, "(").concat(d2, ")");
              n4.startsWith("geid_") ? e2.multi && (void 0 === i3[s2] ? i3[s2] = 0 : i3[s2]++, c2 += "".concat(i3[s2], ". ")) : c2 += "[".concat(n4, "]: "), r3[c2 += s2] = t2.attributes;
            });
            var o2 = {};
            for (var a2 in this) this.hasOwnProperty(a2) && !Ut.has(a2) && "function" != typeof this[a2] && "symbol" !== t(a2) && (o2[a2] = this[a2]);
            return o2.attributes = this._attributes, o2.nodes = n3, o2.edges = r3, p(o2, "constructor", this.constructor), o2;
          }, r2;
        }(y.exports.EventEmitter);
        "undefined" != typeof Symbol && (zt.prototype[Symbol.for("nodejs.util.inspect.custom")] = zt.prototype.inspect), [{ name: function(t2) {
          return "".concat(t2, "Edge");
        }, generateKey: true }, { name: function(t2) {
          return "".concat(t2, "DirectedEdge");
        }, generateKey: true, type: "directed" }, { name: function(t2) {
          return "".concat(t2, "UndirectedEdge");
        }, generateKey: true, type: "undirected" }, { name: function(t2) {
          return "".concat(t2, "EdgeWithKey");
        } }, { name: function(t2) {
          return "".concat(t2, "DirectedEdgeWithKey");
        }, type: "directed" }, { name: function(t2) {
          return "".concat(t2, "UndirectedEdgeWithKey");
        }, type: "undirected" }].forEach(function(t2) {
          ["add", "merge", "update"].forEach(function(e2) {
            var n2 = t2.name(e2), r2 = "add" === e2 ? jt : Ct;
            t2.generateKey ? zt.prototype[n2] = function(i2, o2, a2) {
              return r2(this, n2, true, "undirected" === (t2.type || this.type), null, i2, o2, a2, "update" === e2);
            } : zt.prototype[n2] = function(i2, o2, a2, c2) {
              return r2(this, n2, false, "undirected" === (t2.type || this.type), i2, o2, a2, c2, "update" === e2);
            };
          });
        }), function(t2) {
          Q.forEach(function(e2) {
            var n2 = e2.name, r2 = e2.attacher;
            r2(t2, n2("Node"), 0), r2(t2, n2("Source"), 1), r2(t2, n2("Target"), 2), r2(t2, n2("Opposite"), 3);
          });
        }(zt), function(t2) {
          X.forEach(function(e2) {
            var n2 = e2.name, r2 = e2.attacher;
            r2(t2, n2("Edge"), "mixed"), r2(t2, n2("DirectedEdge"), "directed"), r2(t2, n2("UndirectedEdge"), "undirected");
          });
        }(zt), function(t2) {
          et.forEach(function(e2) {
            !function(t3, e3) {
              var n2 = e3.name, r2 = e3.type, i2 = e3.direction;
              t3.prototype[n2] = function(t4, e4) {
                if ("mixed" !== r2 && "mixed" !== this.type && r2 !== this.type) return [];
                if (!arguments.length) return ut(this, r2);
                if (1 === arguments.length) {
                  t4 = "" + t4;
                  var o2 = this._nodes.get(t4);
                  if (void 0 === o2) throw new F("Graph.".concat(n2, ': could not find the "').concat(t4, '" node in the graph.'));
                  return pt(this.multi, "mixed" === r2 ? this.type : r2, i2, o2);
                }
                if (2 === arguments.length) {
                  t4 = "" + t4, e4 = "" + e4;
                  var a2 = this._nodes.get(t4);
                  if (!a2) throw new F("Graph.".concat(n2, ':  could not find the "').concat(t4, '" source node in the graph.'));
                  if (!this._nodes.has(e4)) throw new F("Graph.".concat(n2, ':  could not find the "').concat(e4, '" target node in the graph.'));
                  return gt(r2, this.multi, i2, a2, e4);
                }
                throw new B("Graph.".concat(n2, ": too many arguments (expecting 0, 1 or 2 and got ").concat(arguments.length, ")."));
              };
            }(t2, e2), function(t3, e3) {
              var n2 = e3.name, r2 = e3.type, i2 = e3.direction, o2 = "forEach" + n2[0].toUpperCase() + n2.slice(1, -1);
              t3.prototype[o2] = function(t4, e4, n3) {
                if ("mixed" === r2 || "mixed" === this.type || r2 === this.type) {
                  if (1 === arguments.length) return dt(false, this, r2, n3 = t4);
                  if (2 === arguments.length) {
                    t4 = "" + t4, n3 = e4;
                    var a3 = this._nodes.get(t4);
                    if (void 0 === a3) throw new F("Graph.".concat(o2, ': could not find the "').concat(t4, '" node in the graph.'));
                    return ht(false, this.multi, "mixed" === r2 ? this.type : r2, i2, a3, n3);
                  }
                  if (3 === arguments.length) {
                    t4 = "" + t4, e4 = "" + e4;
                    var c3 = this._nodes.get(t4);
                    if (!c3) throw new F("Graph.".concat(o2, ':  could not find the "').concat(t4, '" source node in the graph.'));
                    if (!this._nodes.has(e4)) throw new F("Graph.".concat(o2, ':  could not find the "').concat(e4, '" target node in the graph.'));
                    return lt(false, r2, this.multi, i2, c3, e4, n3);
                  }
                  throw new B("Graph.".concat(o2, ": too many arguments (expecting 1, 2 or 3 and got ").concat(arguments.length, ")."));
                }
              };
              var a2 = "map" + n2[0].toUpperCase() + n2.slice(1);
              t3.prototype[a2] = function() {
                var t4, e4 = Array.prototype.slice.call(arguments), n3 = e4.pop();
                if (0 === e4.length) {
                  var i3 = 0;
                  "directed" !== r2 && (i3 += this.undirectedSize), "undirected" !== r2 && (i3 += this.directedSize), t4 = new Array(i3);
                  var a3 = 0;
                  e4.push(function(e5, r3, i4, o3, c3, u3, d2) {
                    t4[a3++] = n3(e5, r3, i4, o3, c3, u3, d2);
                  });
                } else t4 = [], e4.push(function(e5, r3, i4, o3, a4, c3, u3) {
                  t4.push(n3(e5, r3, i4, o3, a4, c3, u3));
                });
                return this[o2].apply(this, e4), t4;
              };
              var c2 = "filter" + n2[0].toUpperCase() + n2.slice(1);
              t3.prototype[c2] = function() {
                var t4 = Array.prototype.slice.call(arguments), e4 = t4.pop(), n3 = [];
                return t4.push(function(t5, r3, i3, o3, a3, c3, u3) {
                  e4(t5, r3, i3, o3, a3, c3, u3) && n3.push(t5);
                }), this[o2].apply(this, t4), n3;
              };
              var u2 = "reduce" + n2[0].toUpperCase() + n2.slice(1);
              t3.prototype[u2] = function() {
                var t4, e4, n3 = Array.prototype.slice.call(arguments);
                if (n3.length < 2 || n3.length > 4) throw new B("Graph.".concat(u2, ": invalid number of arguments (expecting 2, 3 or 4 and got ").concat(n3.length, ")."));
                if ("function" == typeof n3[n3.length - 1] && "function" != typeof n3[n3.length - 2]) throw new B("Graph.".concat(u2, ": missing initial value. You must provide it because the callback takes more than one argument and we cannot infer the initial value from the first iteration, as you could with a simple array."));
                2 === n3.length ? (t4 = n3[0], e4 = n3[1], n3 = []) : 3 === n3.length ? (t4 = n3[1], e4 = n3[2], n3 = [n3[0]]) : 4 === n3.length && (t4 = n3[2], e4 = n3[3], n3 = [n3[0], n3[1]]);
                var r3 = e4;
                return n3.push(function(e5, n4, i3, o3, a3, c3, u3) {
                  r3 = t4(r3, e5, n4, i3, o3, a3, c3, u3);
                }), this[o2].apply(this, n3), r3;
              };
            }(t2, e2), function(t3, e3) {
              var n2 = e3.name, r2 = e3.type, i2 = e3.direction, o2 = "find" + n2[0].toUpperCase() + n2.slice(1, -1);
              t3.prototype[o2] = function(t4, e4, n3) {
                if ("mixed" !== r2 && "mixed" !== this.type && r2 !== this.type) return false;
                if (1 === arguments.length) return dt(true, this, r2, n3 = t4);
                if (2 === arguments.length) {
                  t4 = "" + t4, n3 = e4;
                  var a3 = this._nodes.get(t4);
                  if (void 0 === a3) throw new F("Graph.".concat(o2, ': could not find the "').concat(t4, '" node in the graph.'));
                  return ht(true, this.multi, "mixed" === r2 ? this.type : r2, i2, a3, n3);
                }
                if (3 === arguments.length) {
                  t4 = "" + t4, e4 = "" + e4;
                  var c3 = this._nodes.get(t4);
                  if (!c3) throw new F("Graph.".concat(o2, ':  could not find the "').concat(t4, '" source node in the graph.'));
                  if (!this._nodes.has(e4)) throw new F("Graph.".concat(o2, ':  could not find the "').concat(e4, '" target node in the graph.'));
                  return lt(true, r2, this.multi, i2, c3, e4, n3);
                }
                throw new B("Graph.".concat(o2, ": too many arguments (expecting 1, 2 or 3 and got ").concat(arguments.length, ")."));
              };
              var a2 = "some" + n2[0].toUpperCase() + n2.slice(1, -1);
              t3.prototype[a2] = function() {
                var t4 = Array.prototype.slice.call(arguments), e4 = t4.pop();
                return t4.push(function(t5, n3, r3, i3, o3, a3, c3) {
                  return e4(t5, n3, r3, i3, o3, a3, c3);
                }), !!this[o2].apply(this, t4);
              };
              var c2 = "every" + n2[0].toUpperCase() + n2.slice(1, -1);
              t3.prototype[c2] = function() {
                var t4 = Array.prototype.slice.call(arguments), e4 = t4.pop();
                return t4.push(function(t5, n3, r3, i3, o3, a3, c3) {
                  return !e4(t5, n3, r3, i3, o3, a3, c3);
                }), !this[o2].apply(this, t4);
              };
            }(t2, e2), function(t3, e3) {
              var n2 = e3.name, r2 = e3.type, i2 = e3.direction, o2 = n2.slice(0, -1) + "Entries";
              t3.prototype[o2] = function(t4, e4) {
                if ("mixed" !== r2 && "mixed" !== this.type && r2 !== this.type) return O.empty();
                if (!arguments.length) return st(this, r2);
                if (1 === arguments.length) {
                  t4 = "" + t4;
                  var n3 = this._nodes.get(t4);
                  if (!n3) throw new F("Graph.".concat(o2, ': could not find the "').concat(t4, '" node in the graph.'));
                  return ft(r2, i2, n3);
                }
                if (2 === arguments.length) {
                  t4 = "" + t4, e4 = "" + e4;
                  var a2 = this._nodes.get(t4);
                  if (!a2) throw new F("Graph.".concat(o2, ':  could not find the "').concat(t4, '" source node in the graph.'));
                  if (!this._nodes.has(e4)) throw new F("Graph.".concat(o2, ':  could not find the "').concat(e4, '" target node in the graph.'));
                  return yt(r2, i2, a2, e4);
                }
                throw new B("Graph.".concat(o2, ": too many arguments (expecting 0, 1 or 2 and got ").concat(arguments.length, ")."));
              };
            }(t2, e2);
          });
        }(zt), function(t2) {
          wt.forEach(function(e2) {
            _t(t2, e2), function(t3, e3) {
              var n2 = e3.name, r2 = e3.type, i2 = e3.direction, o2 = "forEach" + n2[0].toUpperCase() + n2.slice(1, -1);
              t3.prototype[o2] = function(t4, e4) {
                if ("mixed" === r2 || "mixed" === this.type || r2 === this.type) {
                  t4 = "" + t4;
                  var n3 = this._nodes.get(t4);
                  if (void 0 === n3) throw new F("Graph.".concat(o2, ': could not find the "').concat(t4, '" node in the graph.'));
                  mt(false, "mixed" === r2 ? this.type : r2, i2, n3, e4);
                }
              };
              var a2 = "map" + n2[0].toUpperCase() + n2.slice(1);
              t3.prototype[a2] = function(t4, e4) {
                var n3 = [];
                return this[o2](t4, function(t5, r3) {
                  n3.push(e4(t5, r3));
                }), n3;
              };
              var c2 = "filter" + n2[0].toUpperCase() + n2.slice(1);
              t3.prototype[c2] = function(t4, e4) {
                var n3 = [];
                return this[o2](t4, function(t5, r3) {
                  e4(t5, r3) && n3.push(t5);
                }), n3;
              };
              var u2 = "reduce" + n2[0].toUpperCase() + n2.slice(1);
              t3.prototype[u2] = function(t4, e4, n3) {
                if (arguments.length < 3) throw new B("Graph.".concat(u2, ": missing initial value. You must provide it because the callback takes more than one argument and we cannot infer the initial value from the first iteration, as you could with a simple array."));
                var r3 = n3;
                return this[o2](t4, function(t5, n4) {
                  r3 = e4(r3, t5, n4);
                }), r3;
              };
            }(t2, e2), function(t3, e3) {
              var n2 = e3.name, r2 = e3.type, i2 = e3.direction, o2 = n2[0].toUpperCase() + n2.slice(1, -1), a2 = "find" + o2;
              t3.prototype[a2] = function(t4, e4) {
                if ("mixed" === r2 || "mixed" === this.type || r2 === this.type) {
                  t4 = "" + t4;
                  var n3 = this._nodes.get(t4);
                  if (void 0 === n3) throw new F("Graph.".concat(a2, ': could not find the "').concat(t4, '" node in the graph.'));
                  return mt(true, "mixed" === r2 ? this.type : r2, i2, n3, e4);
                }
              };
              var c2 = "some" + o2;
              t3.prototype[c2] = function(t4, e4) {
                return !!this[a2](t4, e4);
              };
              var u2 = "every" + o2;
              t3.prototype[u2] = function(t4, e4) {
                return !this[a2](t4, function(t5, n3) {
                  return !e4(t5, n3);
                });
              };
            }(t2, e2), Gt(t2, e2);
          });
        }(zt);
        var Wt = function(t2) {
          function n2(e2) {
            var n3 = u({ type: "directed" }, e2);
            if ("multi" in n3 && false !== n3.multi) throw new B("DirectedGraph.from: inconsistent indication that the graph should be multi in given options!");
            if ("directed" !== n3.type) throw new B('DirectedGraph.from: inconsistent "' + n3.type + '" type in given options!');
            return t2.call(this, n3) || this;
          }
          return e(n2, t2), n2;
        }(zt), Pt = function(t2) {
          function n2(e2) {
            var n3 = u({ type: "undirected" }, e2);
            if ("multi" in n3 && false !== n3.multi) throw new B("UndirectedGraph.from: inconsistent indication that the graph should be multi in given options!");
            if ("undirected" !== n3.type) throw new B('UndirectedGraph.from: inconsistent "' + n3.type + '" type in given options!');
            return t2.call(this, n3) || this;
          }
          return e(n2, t2), n2;
        }(zt), Rt = function(t2) {
          function n2(e2) {
            var n3 = u({ multi: true }, e2);
            if ("multi" in n3 && true !== n3.multi) throw new B("MultiGraph.from: inconsistent indication that the graph should be simple in given options!");
            return t2.call(this, n3) || this;
          }
          return e(n2, t2), n2;
        }(zt), Kt = function(t2) {
          function n2(e2) {
            var n3 = u({ type: "directed", multi: true }, e2);
            if ("multi" in n3 && true !== n3.multi) throw new B("MultiDirectedGraph.from: inconsistent indication that the graph should be simple in given options!");
            if ("directed" !== n3.type) throw new B('MultiDirectedGraph.from: inconsistent "' + n3.type + '" type in given options!');
            return t2.call(this, n3) || this;
          }
          return e(n2, t2), n2;
        }(zt), Tt = function(t2) {
          function n2(e2) {
            var n3 = u({ type: "undirected", multi: true }, e2);
            if ("multi" in n3 && true !== n3.multi) throw new B("MultiUndirectedGraph.from: inconsistent indication that the graph should be simple in given options!");
            if ("undirected" !== n3.type) throw new B('MultiUndirectedGraph.from: inconsistent "' + n3.type + '" type in given options!');
            return t2.call(this, n3) || this;
          }
          return e(n2, t2), n2;
        }(zt);
        function Bt(t2) {
          t2.from = function(e2, n2) {
            var r2 = u({}, e2.options, n2), i2 = new t2(r2);
            return i2.import(e2), i2;
          };
        }
        return Bt(zt), Bt(Wt), Bt(Pt), Bt(Rt), Bt(Kt), Bt(Tt), zt.Graph = zt, zt.DirectedGraph = Wt, zt.UndirectedGraph = Pt, zt.MultiGraph = Rt, zt.MultiDirectedGraph = Kt, zt.MultiUndirectedGraph = Tt, zt.InvalidArgumentsGraphError = B, zt.NotFoundGraphError = F, zt.UsageGraphError = I, zt;
      });
    }
  });

  // vendor/sigma.min.js
  var require_sigma_min = __commonJS({
    "vendor/sigma.min.js"() {
      var Sigma2;
      (() => {
        var t = { 796: (t2) => {
          t2.exports = function(t3, e2) {
            var r2 = e2.length;
            if (0 !== r2) {
              var i2 = t3.length;
              t3.length += r2;
              for (var n = 0; n < r2; n++) t3[i2 + n] = e2[n];
            }
          };
        }, 187: (t2) => {
          "use strict";
          var e2, r2 = "object" == typeof Reflect ? Reflect : null, i2 = r2 && "function" == typeof r2.apply ? r2.apply : function(t3, e3, r3) {
            return Function.prototype.apply.call(t3, e3, r3);
          };
          e2 = r2 && "function" == typeof r2.ownKeys ? r2.ownKeys : Object.getOwnPropertySymbols ? function(t3) {
            return Object.getOwnPropertyNames(t3).concat(Object.getOwnPropertySymbols(t3));
          } : function(t3) {
            return Object.getOwnPropertyNames(t3);
          };
          var n = Number.isNaN || function(t3) {
            return t3 != t3;
          };
          function o() {
            o.init.call(this);
          }
          t2.exports = o, t2.exports.once = function(t3, e3) {
            return new Promise(function(r3, i3) {
              function n2(r4) {
                t3.removeListener(e3, o2), i3(r4);
              }
              function o2() {
                "function" == typeof t3.removeListener && t3.removeListener("error", n2), r3([].slice.call(arguments));
              }
              g(t3, e3, o2, { once: true }), "error" !== e3 && function(t4, e4, r4) {
                "function" == typeof t4.on && g(t4, "error", e4, { once: true });
              }(t3, n2);
            });
          }, o.EventEmitter = o, o.prototype._events = void 0, o.prototype._eventsCount = 0, o.prototype._maxListeners = void 0;
          var a = 10;
          function s(t3) {
            if ("function" != typeof t3) throw new TypeError('The "listener" argument must be of type Function. Received type ' + typeof t3);
          }
          function h(t3) {
            return void 0 === t3._maxListeners ? o.defaultMaxListeners : t3._maxListeners;
          }
          function l(t3, e3, r3, i3) {
            var n2, o2, a2, l2;
            if (s(r3), void 0 === (o2 = t3._events) ? (o2 = t3._events = /* @__PURE__ */ Object.create(null), t3._eventsCount = 0) : (void 0 !== o2.newListener && (t3.emit("newListener", e3, r3.listener ? r3.listener : r3), o2 = t3._events), a2 = o2[e3]), void 0 === a2) a2 = o2[e3] = r3, ++t3._eventsCount;
            else if ("function" == typeof a2 ? a2 = o2[e3] = i3 ? [r3, a2] : [a2, r3] : i3 ? a2.unshift(r3) : a2.push(r3), (n2 = h(t3)) > 0 && a2.length > n2 && !a2.warned) {
              a2.warned = true;
              var c2 = new Error("Possible EventEmitter memory leak detected. " + a2.length + " " + String(e3) + " listeners added. Use emitter.setMaxListeners() to increase limit");
              c2.name = "MaxListenersExceededWarning", c2.emitter = t3, c2.type = e3, c2.count = a2.length, l2 = c2, console && console.warn && console.warn(l2);
            }
            return t3;
          }
          function c() {
            if (!this.fired) return this.target.removeListener(this.type, this.wrapFn), this.fired = true, 0 === arguments.length ? this.listener.call(this.target) : this.listener.apply(this.target, arguments);
          }
          function u(t3, e3, r3) {
            var i3 = { fired: false, wrapFn: void 0, target: t3, type: e3, listener: r3 }, n2 = c.bind(i3);
            return n2.listener = r3, i3.wrapFn = n2, n2;
          }
          function d(t3, e3, r3) {
            var i3 = t3._events;
            if (void 0 === i3) return [];
            var n2 = i3[e3];
            return void 0 === n2 ? [] : "function" == typeof n2 ? r3 ? [n2.listener || n2] : [n2] : r3 ? function(t4) {
              for (var e4 = new Array(t4.length), r4 = 0; r4 < e4.length; ++r4) e4[r4] = t4[r4].listener || t4[r4];
              return e4;
            }(n2) : p(n2, n2.length);
          }
          function f(t3) {
            var e3 = this._events;
            if (void 0 !== e3) {
              var r3 = e3[t3];
              if ("function" == typeof r3) return 1;
              if (void 0 !== r3) return r3.length;
            }
            return 0;
          }
          function p(t3, e3) {
            for (var r3 = new Array(e3), i3 = 0; i3 < e3; ++i3) r3[i3] = t3[i3];
            return r3;
          }
          function g(t3, e3, r3, i3) {
            if ("function" == typeof t3.on) i3.once ? t3.once(e3, r3) : t3.on(e3, r3);
            else {
              if ("function" != typeof t3.addEventListener) throw new TypeError('The "emitter" argument must be of type EventEmitter. Received type ' + typeof t3);
              t3.addEventListener(e3, function n2(o2) {
                i3.once && t3.removeEventListener(e3, n2), r3(o2);
              });
            }
          }
          Object.defineProperty(o, "defaultMaxListeners", { enumerable: true, get: function() {
            return a;
          }, set: function(t3) {
            if ("number" != typeof t3 || t3 < 0 || n(t3)) throw new RangeError('The value of "defaultMaxListeners" is out of range. It must be a non-negative number. Received ' + t3 + ".");
            a = t3;
          } }), o.init = function() {
            void 0 !== this._events && this._events !== Object.getPrototypeOf(this)._events || (this._events = /* @__PURE__ */ Object.create(null), this._eventsCount = 0), this._maxListeners = this._maxListeners || void 0;
          }, o.prototype.setMaxListeners = function(t3) {
            if ("number" != typeof t3 || t3 < 0 || n(t3)) throw new RangeError('The value of "n" is out of range. It must be a non-negative number. Received ' + t3 + ".");
            return this._maxListeners = t3, this;
          }, o.prototype.getMaxListeners = function() {
            return h(this);
          }, o.prototype.emit = function(t3) {
            for (var e3 = [], r3 = 1; r3 < arguments.length; r3++) e3.push(arguments[r3]);
            var n2 = "error" === t3, o2 = this._events;
            if (void 0 !== o2) n2 = n2 && void 0 === o2.error;
            else if (!n2) return false;
            if (n2) {
              var a2;
              if (e3.length > 0 && (a2 = e3[0]), a2 instanceof Error) throw a2;
              var s2 = new Error("Unhandled error." + (a2 ? " (" + a2.message + ")" : ""));
              throw s2.context = a2, s2;
            }
            var h2 = o2[t3];
            if (void 0 === h2) return false;
            if ("function" == typeof h2) i2(h2, this, e3);
            else {
              var l2 = h2.length, c2 = p(h2, l2);
              for (r3 = 0; r3 < l2; ++r3) i2(c2[r3], this, e3);
            }
            return true;
          }, o.prototype.addListener = function(t3, e3) {
            return l(this, t3, e3, false);
          }, o.prototype.on = o.prototype.addListener, o.prototype.prependListener = function(t3, e3) {
            return l(this, t3, e3, true);
          }, o.prototype.once = function(t3, e3) {
            return s(e3), this.on(t3, u(this, t3, e3)), this;
          }, o.prototype.prependOnceListener = function(t3, e3) {
            return s(e3), this.prependListener(t3, u(this, t3, e3)), this;
          }, o.prototype.removeListener = function(t3, e3) {
            var r3, i3, n2, o2, a2;
            if (s(e3), void 0 === (i3 = this._events)) return this;
            if (void 0 === (r3 = i3[t3])) return this;
            if (r3 === e3 || r3.listener === e3) 0 == --this._eventsCount ? this._events = /* @__PURE__ */ Object.create(null) : (delete i3[t3], i3.removeListener && this.emit("removeListener", t3, r3.listener || e3));
            else if ("function" != typeof r3) {
              for (n2 = -1, o2 = r3.length - 1; o2 >= 0; o2--) if (r3[o2] === e3 || r3[o2].listener === e3) {
                a2 = r3[o2].listener, n2 = o2;
                break;
              }
              if (n2 < 0) return this;
              0 === n2 ? r3.shift() : function(t4, e4) {
                for (; e4 + 1 < t4.length; e4++) t4[e4] = t4[e4 + 1];
                t4.pop();
              }(r3, n2), 1 === r3.length && (i3[t3] = r3[0]), void 0 !== i3.removeListener && this.emit("removeListener", t3, a2 || e3);
            }
            return this;
          }, o.prototype.off = o.prototype.removeListener, o.prototype.removeAllListeners = function(t3) {
            var e3, r3, i3;
            if (void 0 === (r3 = this._events)) return this;
            if (void 0 === r3.removeListener) return 0 === arguments.length ? (this._events = /* @__PURE__ */ Object.create(null), this._eventsCount = 0) : void 0 !== r3[t3] && (0 == --this._eventsCount ? this._events = /* @__PURE__ */ Object.create(null) : delete r3[t3]), this;
            if (0 === arguments.length) {
              var n2, o2 = Object.keys(r3);
              for (i3 = 0; i3 < o2.length; ++i3) "removeListener" !== (n2 = o2[i3]) && this.removeAllListeners(n2);
              return this.removeAllListeners("removeListener"), this._events = /* @__PURE__ */ Object.create(null), this._eventsCount = 0, this;
            }
            if ("function" == typeof (e3 = r3[t3])) this.removeListener(t3, e3);
            else if (void 0 !== e3) for (i3 = e3.length - 1; i3 >= 0; i3--) this.removeListener(t3, e3[i3]);
            return this;
          }, o.prototype.listeners = function(t3) {
            return d(this, t3, true);
          }, o.prototype.rawListeners = function(t3) {
            return d(this, t3, false);
          }, o.listenerCount = function(t3, e3) {
            return "function" == typeof t3.listenerCount ? t3.listenerCount(e3) : f.call(t3, e3);
          }, o.prototype.listenerCount = f, o.prototype.eventNames = function() {
            return this._eventsCount > 0 ? e2(this._events) : [];
          };
        }, 186: (t2) => {
          t2.exports = function(t3) {
            return null !== t3 && "object" == typeof t3 && "function" == typeof t3.addUndirectedEdgeWithKey && "function" == typeof t3.dropNode && "boolean" == typeof t3.multi;
          };
        }, 973: (t2, e2, r2) => {
          "use strict";
          r2.r(e2), r2.d(e2, { default: () => i2 });
          const i2 = "precision mediump float;\n\nvarying vec4 v_color;\n\nvoid main(void) {\n  gl_FragColor = v_color;\n}\n";
        }, 912: (t2, e2, r2) => {
          "use strict";
          r2.r(e2), r2.d(e2, { default: () => i2 });
          const i2 = "attribute vec2 a_position;\nattribute vec2 a_normal;\nattribute float a_radius;\nattribute vec4 a_color;\nattribute vec3 a_barycentric;\n\nuniform mat3 u_matrix;\nuniform float u_sqrtZoomRatio;\nuniform float u_correctionRatio;\n\nvarying vec4 v_color;\n\nconst float minThickness = 1.7;\nconst float bias = 255.0 / 254.0;\nconst float arrowHeadWidthLengthRatio = 0.66;\nconst float arrowHeadLengthThicknessRatio = 2.5;\n\nvoid main() {\n  float normalLength = length(a_normal);\n  vec2 unitNormal = a_normal / normalLength;\n\n  // These first computations are taken from edge.vert.glsl and\n  // edge.clamped.vert.glsl. Please read it to get better comments on what's\n  // happening:\n  float pixelsThickness = max(normalLength, minThickness * u_sqrtZoomRatio);\n  float webGLThickness = pixelsThickness * u_correctionRatio;\n  float adaptedWebGLThickness = webGLThickness * u_sqrtZoomRatio;\n  float adaptedWebGLNodeRadius = a_radius * 2.0 * u_correctionRatio * u_sqrtZoomRatio;\n  float adaptedWebGLArrowHeadLength = adaptedWebGLThickness * 2.0 * arrowHeadLengthThicknessRatio;\n  float adaptedWebGLArrowHeadHalfWidth = adaptedWebGLArrowHeadLength * arrowHeadWidthLengthRatio / 2.0;\n\n  float da = a_barycentric.x;\n  float db = a_barycentric.y;\n  float dc = a_barycentric.z;\n\n  vec2 delta = vec2(\n      da * (adaptedWebGLNodeRadius * unitNormal.y)\n    + db * ((adaptedWebGLNodeRadius + adaptedWebGLArrowHeadLength) * unitNormal.y + adaptedWebGLArrowHeadHalfWidth * unitNormal.x)\n    + dc * ((adaptedWebGLNodeRadius + adaptedWebGLArrowHeadLength) * unitNormal.y - adaptedWebGLArrowHeadHalfWidth * unitNormal.x),\n\n      da * (-adaptedWebGLNodeRadius * unitNormal.x)\n    + db * (-(adaptedWebGLNodeRadius + adaptedWebGLArrowHeadLength) * unitNormal.x + adaptedWebGLArrowHeadHalfWidth * unitNormal.y)\n    + dc * (-(adaptedWebGLNodeRadius + adaptedWebGLArrowHeadLength) * unitNormal.x - adaptedWebGLArrowHeadHalfWidth * unitNormal.y)\n  );\n\n  vec2 position = (u_matrix * vec3(a_position + delta, 1)).xy;\n\n  gl_Position = vec4(position, 0, 1);\n\n  // Extract the color:\n  v_color = a_color;\n  v_color.a *= bias;\n}\n";
        }, 620: (t2, e2, r2) => {
          "use strict";
          r2.r(e2), r2.d(e2, { default: () => i2 });
          const i2 = "attribute vec4 a_color;\nattribute vec2 a_normal;\nattribute vec2 a_position;\nattribute float a_radius;\n\nuniform mat3 u_matrix;\nuniform float u_sqrtZoomRatio;\nuniform float u_correctionRatio;\n\nvarying vec4 v_color;\nvarying vec2 v_normal;\nvarying float v_thickness;\n\nconst float minThickness = 1.7;\nconst float bias = 255.0 / 254.0;\nconst float arrowHeadLengthThicknessRatio = 2.5;\n\nvoid main() {\n  float normalLength = length(a_normal);\n  vec2 unitNormal = a_normal / normalLength;\n\n  // These first computations are taken from edge.vert.glsl. Please read it to\n  // get better comments on what's happening:\n  float pixelsThickness = max(normalLength, minThickness * u_sqrtZoomRatio);\n  float webGLThickness = pixelsThickness * u_correctionRatio;\n  float adaptedWebGLThickness = webGLThickness * u_sqrtZoomRatio;\n\n  // Here, we move the point to leave space for the arrow head:\n  float direction = sign(a_radius);\n  float adaptedWebGLNodeRadius = direction * a_radius * 2.0 * u_correctionRatio * u_sqrtZoomRatio;\n  float adaptedWebGLArrowHeadLength = adaptedWebGLThickness * 2.0 * arrowHeadLengthThicknessRatio;\n\n  vec2 compensationVector = vec2(-direction * unitNormal.y, direction * unitNormal.x) * (adaptedWebGLNodeRadius + adaptedWebGLArrowHeadLength);\n\n  // Here is the proper position of the vertex\n  gl_Position = vec4((u_matrix * vec3(a_position + unitNormal * adaptedWebGLThickness + compensationVector, 1)).xy, 0, 1);\n\n  v_thickness = webGLThickness / u_sqrtZoomRatio;\n\n  v_normal = unitNormal;\n  v_color = a_color;\n  v_color.a *= bias;\n}\n";
        }, 498: (t2, e2, r2) => {
          "use strict";
          r2.r(e2), r2.d(e2, { default: () => i2 });
          const i2 = "precision mediump float;\n\nvarying vec4 v_color;\nvarying vec2 v_normal;\nvarying float v_thickness;\n\nconst float feather = 0.001;\nconst vec4 transparent = vec4(0.0, 0.0, 0.0, 0.0);\n\nvoid main(void) {\n  float dist = length(v_normal) * v_thickness;\n\n  float t = smoothstep(\n    v_thickness - feather,\n    v_thickness,\n    dist\n  );\n\n  gl_FragColor = mix(v_color, transparent, t);\n}\n";
        }, 223: (t2, e2, r2) => {
          "use strict";
          r2.r(e2), r2.d(e2, { default: () => i2 });
          const i2 = 'attribute vec4 a_color;\nattribute vec2 a_normal;\nattribute vec2 a_position;\n\nuniform mat3 u_matrix;\nuniform float u_sqrtZoomRatio;\nuniform float u_correctionRatio;\n\nvarying vec4 v_color;\nvarying vec2 v_normal;\nvarying float v_thickness;\n\nconst float minThickness = 1.7;\nconst float bias = 255.0 / 254.0;\n\nvoid main() {\n  float normalLength = length(a_normal);\n  vec2 unitNormal = a_normal / normalLength;\n\n  // We require edges to be at least `minThickness` pixels thick *on screen*\n  // (so we need to compensate the SQRT zoom ratio):\n  float pixelsThickness = max(normalLength, minThickness * u_sqrtZoomRatio);\n\n  // Then, we need to retrieve the normalized thickness of the edge in the WebGL\n  // referential (in a ([0, 1], [0, 1]) space), using our "magic" correction\n  // ratio:\n  float webGLThickness = pixelsThickness * u_correctionRatio;\n\n  // Finally, we adapt the edge thickness to the "SQRT rule" in sigma (so that\n  // items are not too big when zoomed in, and not too small when zoomed out).\n  // The exact computation should be `adapted = value * zoom / sqrt(zoom)`, but\n  // it\'s simpler like this:\n  float adaptedWebGLThickness = webGLThickness * u_sqrtZoomRatio;\n\n  // Here is the proper position of the vertex\n  gl_Position = vec4((u_matrix * vec3(a_position + unitNormal * adaptedWebGLThickness, 1)).xy, 0, 1);\n\n  // For the fragment shader though, we need a thickness that takes the "magic"\n  // correction ratio into account (as in webGLThickness), but so that the\n  // antialiasing effect does not depend on the zoom level. So here\'s yet\n  // another thickness version:\n  v_thickness = webGLThickness / u_sqrtZoomRatio;\n\n  v_normal = unitNormal;\n  v_color = a_color;\n  v_color.a *= bias;\n}\n';
        }, 262: (t2, e2, r2) => {
          "use strict";
          r2.r(e2), r2.d(e2, { default: () => i2 });
          const i2 = "precision mediump float;\n\nvarying vec4 v_color;\nvarying float v_border;\n\nconst float radius = 0.5;\nconst vec4 transparent = vec4(0.0, 0.0, 0.0, 0.0);\n\nvoid main(void) {\n  vec2 m = gl_PointCoord - vec2(0.5, 0.5);\n  float dist = radius - length(m);\n\n  float t = 0.0;\n  if (dist > v_border)\n    t = 1.0;\n  else if (dist > 0.0)\n    t = dist / v_border;\n\n  gl_FragColor = mix(transparent, v_color, t);\n}\n";
        }, 106: (t2, e2, r2) => {
          "use strict";
          r2.r(e2), r2.d(e2, { default: () => i2 });
          const i2 = "attribute vec2 a_position;\nattribute float a_size;\nattribute vec4 a_color;\n\nuniform float u_ratio;\nuniform float u_scale;\nuniform mat3 u_matrix;\n\nvarying vec4 v_color;\nvarying float v_border;\n\nconst float bias = 255.0 / 254.0;\n\nvoid main() {\n  gl_Position = vec4(\n    (u_matrix * vec3(a_position, 1)).xy,\n    0,\n    1\n  );\n\n  // Multiply the point size twice:\n  //  - x SCALING_RATIO to correct the canvas scaling\n  //  - x 2 to correct the formulae\n  gl_PointSize = a_size * u_ratio * u_scale * 2.0;\n\n  v_border = (1.0 / u_ratio) * (0.5 / a_size);\n\n  // Extract the color:\n  v_color = a_color;\n  v_color.a *= bias;\n}\n";
        }, 764: function(t2, e2, r2) {
          "use strict";
          var i2, n = this && this.__extends || (i2 = function(t3, e3) {
            return i2 = Object.setPrototypeOf || { __proto__: [] } instanceof Array && function(t4, e4) {
              t4.__proto__ = e4;
            } || function(t4, e4) {
              for (var r3 in e4) Object.prototype.hasOwnProperty.call(e4, r3) && (t4[r3] = e4[r3]);
            }, i2(t3, e3);
          }, function(t3, e3) {
            if ("function" != typeof e3 && null !== e3) throw new TypeError("Class extends value " + String(e3) + " is not a constructor or null");
            function r3() {
              this.constructor = t3;
            }
            i2(t3, e3), t3.prototype = null === e3 ? Object.create(e3) : (r3.prototype = e3.prototype, new r3());
          }), o = this && this.__importDefault || function(t3) {
            return t3 && t3.__esModule ? t3 : { default: t3 };
          };
          Object.defineProperty(e2, "__esModule", { value: true });
          var a = r2(751), s = o(r2(358)), h = r2(928), l = r2(699), c = 1.5, u = function(t3) {
            function e3() {
              var e4 = t3.call(this) || this;
              return e4.x = 0.5, e4.y = 0.5, e4.angle = 0, e4.ratio = 1, e4.minRatio = null, e4.maxRatio = null, e4.nextFrame = null, e4.previousState = null, e4.enabled = true, e4.previousState = e4.getState(), e4;
            }
            return n(e3, t3), e3.from = function(t4) {
              return new e3().setState(t4);
            }, e3.prototype.enable = function() {
              return this.enabled = true, this;
            }, e3.prototype.disable = function() {
              return this.enabled = false, this;
            }, e3.prototype.getState = function() {
              return { x: this.x, y: this.y, angle: this.angle, ratio: this.ratio };
            }, e3.prototype.hasState = function(t4) {
              return this.x === t4.x && this.y === t4.y && this.ratio === t4.ratio && this.angle === t4.angle;
            }, e3.prototype.getPreviousState = function() {
              var t4 = this.previousState;
              return t4 ? { x: t4.x, y: t4.y, angle: t4.angle, ratio: t4.ratio } : null;
            }, e3.prototype.getBoundedRatio = function(t4) {
              var e4 = t4;
              return "number" == typeof this.minRatio && (e4 = Math.max(e4, this.minRatio)), "number" == typeof this.maxRatio && (e4 = Math.min(e4, this.maxRatio)), e4;
            }, e3.prototype.validateState = function(t4) {
              var e4 = {};
              return "number" == typeof t4.x && (e4.x = t4.x), "number" == typeof t4.y && (e4.y = t4.y), "number" == typeof t4.angle && (e4.angle = t4.angle), "number" == typeof t4.ratio && (e4.ratio = this.getBoundedRatio(t4.ratio)), e4;
            }, e3.prototype.isAnimated = function() {
              return !!this.nextFrame;
            }, e3.prototype.setState = function(t4) {
              if (!this.enabled) return this;
              this.previousState = this.getState();
              var e4 = this.validateState(t4);
              return "number" == typeof e4.x && (this.x = e4.x), "number" == typeof e4.y && (this.y = e4.y), "number" == typeof e4.angle && (this.angle = e4.angle), "number" == typeof e4.ratio && (this.ratio = e4.ratio), this.hasState(this.previousState) || this.emit("updated", this.getState()), this;
            }, e3.prototype.updateState = function(t4) {
              return this.setState(t4(this.getState())), this;
            }, e3.prototype.animate = function(t4, e4, r3) {
              var i3 = this;
              if (this.enabled) {
                var n2 = Object.assign({}, a.ANIMATE_DEFAULTS, e4), o2 = this.validateState(t4), l2 = "function" == typeof n2.easing ? n2.easing : s.default[n2.easing], c2 = Date.now(), u2 = this.getState(), d = function() {
                  var t5 = (Date.now() - c2) / n2.duration;
                  if (t5 >= 1) return i3.nextFrame = null, i3.setState(o2), void (i3.animationCallback && (i3.animationCallback.call(null), i3.animationCallback = void 0));
                  var e5 = l2(t5), r4 = {};
                  "number" == typeof o2.x && (r4.x = u2.x + (o2.x - u2.x) * e5), "number" == typeof o2.y && (r4.y = u2.y + (o2.y - u2.y) * e5), "number" == typeof o2.angle && (r4.angle = u2.angle + (o2.angle - u2.angle) * e5), "number" == typeof o2.ratio && (r4.ratio = u2.ratio + (o2.ratio - u2.ratio) * e5), i3.setState(r4), i3.nextFrame = (0, h.requestFrame)(d);
                };
                this.nextFrame ? ((0, h.cancelFrame)(this.nextFrame), this.animationCallback && this.animationCallback.call(null), this.nextFrame = (0, h.requestFrame)(d)) : d(), this.animationCallback = r3;
              }
            }, e3.prototype.animatedZoom = function(t4) {
              if (t4) {
                if ("number" == typeof t4) return this.animate({ ratio: this.ratio / t4 });
                this.animate({ ratio: this.ratio / (t4.factor || c) }, t4);
              } else this.animate({ ratio: this.ratio / c });
            }, e3.prototype.animatedUnzoom = function(t4) {
              if (t4) {
                if ("number" == typeof t4) return this.animate({ ratio: this.ratio * t4 });
                this.animate({ ratio: this.ratio * (t4.factor || c) }, t4);
              } else this.animate({ ratio: this.ratio * c });
            }, e3.prototype.animatedReset = function(t4) {
              this.animate({ x: 0.5, y: 0.5, ratio: 1, angle: 0 }, t4);
            }, e3.prototype.copy = function() {
              return e3.from(this.getState());
            }, e3;
          }(l.TypedEventEmitter);
          e2.default = u;
        }, 291: function(t2, e2, r2) {
          "use strict";
          var i2, n = this && this.__extends || (i2 = function(t3, e3) {
            return i2 = Object.setPrototypeOf || { __proto__: [] } instanceof Array && function(t4, e4) {
              t4.__proto__ = e4;
            } || function(t4, e4) {
              for (var r3 in e4) Object.prototype.hasOwnProperty.call(e4, r3) && (t4[r3] = e4[r3]);
            }, i2(t3, e3);
          }, function(t3, e3) {
            if ("function" != typeof e3 && null !== e3) throw new TypeError("Class extends value " + String(e3) + " is not a constructor or null");
            function r3() {
              this.constructor = t3;
            }
            i2(t3, e3), t3.prototype = null === e3 ? Object.create(e3) : (r3.prototype = e3.prototype, new r3());
          }), o = this && this.__assign || function() {
            return o = Object.assign || function(t3) {
              for (var e3, r3 = 1, i3 = arguments.length; r3 < i3; r3++) for (var n2 in e3 = arguments[r3]) Object.prototype.hasOwnProperty.call(e3, n2) && (t3[n2] = e3[n2]);
              return t3;
            }, o.apply(this, arguments);
          };
          Object.defineProperty(e2, "__esModule", { value: true }), e2.getWheelDelta = e2.getTouchCoords = e2.getTouchesArray = e2.getWheelCoords = e2.getMouseCoords = e2.getPosition = void 0;
          var a = r2(699);
          function s(t3, e3) {
            var r3 = e3.getBoundingClientRect();
            return { x: t3.clientX - r3.left, y: t3.clientY - r3.top };
          }
          function h(t3, e3) {
            var r3 = o(o({}, s(t3, e3)), { sigmaDefaultPrevented: false, preventSigmaDefault: function() {
              r3.sigmaDefaultPrevented = true;
            }, original: t3 });
            return r3;
          }
          function l(t3) {
            for (var e3 = [], r3 = 0, i3 = Math.min(t3.length, 2); r3 < i3; r3++) e3.push(t3[r3]);
            return e3;
          }
          function c(t3) {
            if (void 0 !== t3.deltaY) return -3 * t3.deltaY / 360;
            if (void 0 !== t3.detail) return t3.detail / -9;
            throw new Error("Captor: could not extract delta from event.");
          }
          e2.getPosition = s, e2.getMouseCoords = h, e2.getWheelCoords = function(t3, e3) {
            return o(o({}, h(t3, e3)), { delta: c(t3) });
          }, e2.getTouchesArray = l, e2.getTouchCoords = function(t3, e3) {
            return { touches: l(t3.touches).map(function(t4) {
              return s(t4, e3);
            }), original: t3 };
          }, e2.getWheelDelta = c;
          var u = function(t3) {
            function e3(e4, r3) {
              var i3 = t3.call(this) || this;
              return i3.container = e4, i3.renderer = r3, i3;
            }
            return n(e3, t3), e3;
          }(a.TypedEventEmitter);
          e2.default = u;
        }, 269: function(t2, e2, r2) {
          "use strict";
          var i2, n = this && this.__extends || (i2 = function(t3, e3) {
            return i2 = Object.setPrototypeOf || { __proto__: [] } instanceof Array && function(t4, e4) {
              t4.__proto__ = e4;
            } || function(t4, e4) {
              for (var r3 in e4) Object.prototype.hasOwnProperty.call(e4, r3) && (t4[r3] = e4[r3]);
            }, i2(t3, e3);
          }, function(t3, e3) {
            if ("function" != typeof e3 && null !== e3) throw new TypeError("Class extends value " + String(e3) + " is not a constructor or null");
            function r3() {
              this.constructor = t3;
            }
            i2(t3, e3), t3.prototype = null === e3 ? Object.create(e3) : (r3.prototype = e3.prototype, new r3());
          }), o = this && this.__createBinding || (Object.create ? function(t3, e3, r3, i3) {
            void 0 === i3 && (i3 = r3), Object.defineProperty(t3, i3, { enumerable: true, get: function() {
              return e3[r3];
            } });
          } : function(t3, e3, r3, i3) {
            void 0 === i3 && (i3 = r3), t3[i3] = e3[r3];
          }), a = this && this.__setModuleDefault || (Object.create ? function(t3, e3) {
            Object.defineProperty(t3, "default", { enumerable: true, value: e3 });
          } : function(t3, e3) {
            t3.default = e3;
          }), s = this && this.__importStar || function(t3) {
            if (t3 && t3.__esModule) return t3;
            var e3 = {};
            if (null != t3) for (var r3 in t3) "default" !== r3 && Object.prototype.hasOwnProperty.call(t3, r3) && o(e3, t3, r3);
            return a(e3, t3), e3;
          };
          Object.defineProperty(e2, "__esModule", { value: true });
          var h = s(r2(291)), l = function(t3) {
            function e3(e4, r3) {
              var i3 = t3.call(this, e4, r3) || this;
              return i3.enabled = true, i3.draggedEvents = 0, i3.downStartTime = null, i3.lastMouseX = null, i3.lastMouseY = null, i3.isMouseDown = false, i3.isMoving = false, i3.movingTimeout = null, i3.startCameraState = null, i3.clicks = 0, i3.doubleClickTimeout = null, i3.currentWheelDirection = 0, i3.handleClick = i3.handleClick.bind(i3), i3.handleRightClick = i3.handleRightClick.bind(i3), i3.handleDown = i3.handleDown.bind(i3), i3.handleUp = i3.handleUp.bind(i3), i3.handleMove = i3.handleMove.bind(i3), i3.handleWheel = i3.handleWheel.bind(i3), i3.handleOut = i3.handleOut.bind(i3), e4.addEventListener("click", i3.handleClick, false), e4.addEventListener("contextmenu", i3.handleRightClick, false), e4.addEventListener("mousedown", i3.handleDown, false), e4.addEventListener("wheel", i3.handleWheel, false), e4.addEventListener("mouseout", i3.handleOut, false), document.addEventListener("mousemove", i3.handleMove, false), document.addEventListener("mouseup", i3.handleUp, false), i3;
            }
            return n(e3, t3), e3.prototype.kill = function() {
              var t4 = this.container;
              t4.removeEventListener("click", this.handleClick), t4.removeEventListener("contextmenu", this.handleRightClick), t4.removeEventListener("mousedown", this.handleDown), t4.removeEventListener("wheel", this.handleWheel), t4.removeEventListener("mouseout", this.handleOut), document.removeEventListener("mousemove", this.handleMove), document.removeEventListener("mouseup", this.handleUp);
            }, e3.prototype.handleClick = function(t4) {
              var e4 = this;
              if (this.enabled) {
                if (this.clicks++, 2 === this.clicks) return this.clicks = 0, "number" == typeof this.doubleClickTimeout && (clearTimeout(this.doubleClickTimeout), this.doubleClickTimeout = null), this.handleDoubleClick(t4);
                setTimeout(function() {
                  e4.clicks = 0, e4.doubleClickTimeout = null;
                }, 300), this.draggedEvents < 3 && this.emit("click", (0, h.getMouseCoords)(t4, this.container));
              }
            }, e3.prototype.handleRightClick = function(t4) {
              this.enabled && this.emit("rightClick", (0, h.getMouseCoords)(t4, this.container));
            }, e3.prototype.handleDoubleClick = function(t4) {
              if (this.enabled) {
                t4.preventDefault(), t4.stopPropagation();
                var e4 = (0, h.getMouseCoords)(t4, this.container);
                if (this.emit("doubleClick", e4), !e4.sigmaDefaultPrevented) {
                  var r3 = this.renderer.getCamera(), i3 = r3.getBoundedRatio(r3.getState().ratio / 2.2);
                  r3.animate(this.renderer.getViewportZoomedState((0, h.getPosition)(t4, this.container), i3), { easing: "quadraticInOut", duration: 200 });
                }
              }
            }, e3.prototype.handleDown = function(t4) {
              if (this.enabled) {
                if (0 === t4.button) {
                  this.startCameraState = this.renderer.getCamera().getState();
                  var e4 = (0, h.getPosition)(t4, this.container), r3 = e4.x, i3 = e4.y;
                  this.lastMouseX = r3, this.lastMouseY = i3, this.draggedEvents = 0, this.downStartTime = Date.now(), this.isMouseDown = true;
                }
                this.emit("mousedown", (0, h.getMouseCoords)(t4, this.container));
              }
            }, e3.prototype.handleUp = function(t4) {
              var e4 = this;
              if (this.enabled && this.isMouseDown) {
                var r3 = this.renderer.getCamera();
                this.isMouseDown = false, "number" == typeof this.movingTimeout && (clearTimeout(this.movingTimeout), this.movingTimeout = null);
                var i3 = (0, h.getPosition)(t4, this.container), n2 = i3.x, o2 = i3.y, a2 = r3.getState(), s2 = r3.getPreviousState() || { x: 0, y: 0 };
                this.isMoving ? r3.animate({ x: a2.x + 3 * (a2.x - s2.x), y: a2.y + 3 * (a2.y - s2.y) }, { duration: 200, easing: "quadraticOut" }) : this.lastMouseX === n2 && this.lastMouseY === o2 || r3.setState({ x: a2.x, y: a2.y }), this.isMoving = false, setTimeout(function() {
                  e4.draggedEvents = 0, e4.renderer.refresh();
                }, 0), this.emit("mouseup", (0, h.getMouseCoords)(t4, this.container));
              }
            }, e3.prototype.handleMove = function(t4) {
              var e4 = this;
              if (this.enabled) {
                var r3 = (0, h.getMouseCoords)(t4, this.container);
                if (this.emit("mousemovebody", r3), t4.target === this.container && this.emit("mousemove", r3), !r3.sigmaDefaultPrevented && this.isMouseDown) {
                  this.isMoving = true, this.draggedEvents++, "number" == typeof this.movingTimeout && clearTimeout(this.movingTimeout), this.movingTimeout = window.setTimeout(function() {
                    e4.movingTimeout = null, e4.isMoving = false;
                  }, 100);
                  var i3 = this.renderer.getCamera(), n2 = (0, h.getPosition)(t4, this.container), o2 = n2.x, a2 = n2.y, s2 = this.renderer.viewportToFramedGraph({ x: this.lastMouseX, y: this.lastMouseY }), l2 = this.renderer.viewportToFramedGraph({ x: o2, y: a2 }), c = s2.x - l2.x, u = s2.y - l2.y, d = i3.getState(), f = d.x + c, p = d.y + u;
                  i3.setState({ x: f, y: p }), this.lastMouseX = o2, this.lastMouseY = a2, t4.preventDefault(), t4.stopPropagation();
                }
              }
            }, e3.prototype.handleWheel = function(t4) {
              var e4 = this;
              if (this.enabled) {
                t4.preventDefault(), t4.stopPropagation();
                var r3 = (0, h.getWheelDelta)(t4);
                if (r3) {
                  var i3 = (0, h.getWheelCoords)(t4, this.container);
                  if (this.emit("wheel", i3), !i3.sigmaDefaultPrevented) {
                    var n2 = r3 > 0 ? 1 / 1.7 : 1.7, o2 = this.renderer.getCamera(), a2 = o2.getBoundedRatio(o2.getState().ratio * n2), s2 = r3 > 0 ? 1 : -1, l2 = Date.now();
                    this.currentWheelDirection === s2 && this.lastWheelTriggerTime && l2 - this.lastWheelTriggerTime < 50 || (o2.animate(this.renderer.getViewportZoomedState((0, h.getPosition)(t4, this.container), a2), { easing: "quadraticOut", duration: 250 }, function() {
                      e4.currentWheelDirection = 0;
                    }), this.currentWheelDirection = s2, this.lastWheelTriggerTime = l2);
                  }
                }
              }
            }, e3.prototype.handleOut = function() {
            }, e3;
          }(h.default);
          e2.default = l;
        }, 508: function(t2, e2, r2) {
          "use strict";
          var i2, n = this && this.__extends || (i2 = function(t3, e3) {
            return i2 = Object.setPrototypeOf || { __proto__: [] } instanceof Array && function(t4, e4) {
              t4.__proto__ = e4;
            } || function(t4, e4) {
              for (var r3 in e4) Object.prototype.hasOwnProperty.call(e4, r3) && (t4[r3] = e4[r3]);
            }, i2(t3, e3);
          }, function(t3, e3) {
            if ("function" != typeof e3 && null !== e3) throw new TypeError("Class extends value " + String(e3) + " is not a constructor or null");
            function r3() {
              this.constructor = t3;
            }
            i2(t3, e3), t3.prototype = null === e3 ? Object.create(e3) : (r3.prototype = e3.prototype, new r3());
          }), o = this && this.__createBinding || (Object.create ? function(t3, e3, r3, i3) {
            void 0 === i3 && (i3 = r3), Object.defineProperty(t3, i3, { enumerable: true, get: function() {
              return e3[r3];
            } });
          } : function(t3, e3, r3, i3) {
            void 0 === i3 && (i3 = r3), t3[i3] = e3[r3];
          }), a = this && this.__setModuleDefault || (Object.create ? function(t3, e3) {
            Object.defineProperty(t3, "default", { enumerable: true, value: e3 });
          } : function(t3, e3) {
            t3.default = e3;
          }), s = this && this.__importStar || function(t3) {
            if (t3 && t3.__esModule) return t3;
            var e3 = {};
            if (null != t3) for (var r3 in t3) "default" !== r3 && Object.prototype.hasOwnProperty.call(t3, r3) && o(e3, t3, r3);
            return a(e3, t3), e3;
          }, h = this && this.__read || function(t3, e3) {
            var r3 = "function" == typeof Symbol && t3[Symbol.iterator];
            if (!r3) return t3;
            var i3, n2, o2 = r3.call(t3), a2 = [];
            try {
              for (; (void 0 === e3 || e3-- > 0) && !(i3 = o2.next()).done; ) a2.push(i3.value);
            } catch (t4) {
              n2 = { error: t4 };
            } finally {
              try {
                i3 && !i3.done && (r3 = o2.return) && r3.call(o2);
              } finally {
                if (n2) throw n2.error;
              }
            }
            return a2;
          };
          Object.defineProperty(e2, "__esModule", { value: true });
          var l = s(r2(291)), c = function(t3) {
            function e3(e4, r3) {
              var i3 = t3.call(this, e4, r3) || this;
              return i3.enabled = true, i3.isMoving = false, i3.hasMoved = false, i3.touchMode = 0, i3.startTouchesPositions = [], i3.handleStart = i3.handleStart.bind(i3), i3.handleLeave = i3.handleLeave.bind(i3), i3.handleMove = i3.handleMove.bind(i3), e4.addEventListener("touchstart", i3.handleStart, false), e4.addEventListener("touchend", i3.handleLeave, false), e4.addEventListener("touchcancel", i3.handleLeave, false), e4.addEventListener("touchmove", i3.handleMove, false), i3;
            }
            return n(e3, t3), e3.prototype.kill = function() {
              var t4 = this.container;
              t4.removeEventListener("touchstart", this.handleStart), t4.removeEventListener("touchend", this.handleLeave), t4.removeEventListener("touchcancel", this.handleLeave), t4.removeEventListener("touchmove", this.handleMove);
            }, e3.prototype.getDimensions = function() {
              return { width: this.container.offsetWidth, height: this.container.offsetHeight };
            }, e3.prototype.dispatchRelatedMouseEvent = function(t4, e4, r3, i3) {
              var n2 = r3 || e4.touches[0], o2 = new MouseEvent(t4, { clientX: n2.clientX, clientY: n2.clientY, altKey: e4.altKey, ctrlKey: e4.ctrlKey });
              o2.isFakeSigmaMouseEvent = true, (i3 || this.container).dispatchEvent(o2);
            }, e3.prototype.handleStart = function(t4) {
              var e4 = this;
              if (this.enabled) {
                t4.preventDefault(), 1 === t4.touches.length && this.dispatchRelatedMouseEvent("mousedown", t4);
                var r3 = (0, l.getTouchesArray)(t4.touches);
                if (this.touchMode = r3.length, this.startCameraState = this.renderer.getCamera().getState(), this.startTouchesPositions = r3.map(function(t5) {
                  return (0, l.getPosition)(t5, e4.container);
                }), this.lastTouches = r3, this.lastTouchesPositions = this.startTouchesPositions, 2 === this.touchMode) {
                  var i3 = h(this.startTouchesPositions, 2), n2 = i3[0], o2 = n2.x, a2 = n2.y, s2 = i3[1], c2 = s2.x, u = s2.y;
                  this.startTouchesAngle = Math.atan2(u - a2, c2 - o2), this.startTouchesDistance = Math.sqrt(Math.pow(c2 - o2, 2) + Math.pow(u - a2, 2));
                }
                this.emit("touchdown", (0, l.getTouchCoords)(t4, this.container));
              }
            }, e3.prototype.handleLeave = function(t4) {
              if (this.enabled) {
                switch (t4.preventDefault(), 0 === t4.touches.length && this.lastTouches && this.lastTouches.length && (this.dispatchRelatedMouseEvent("mouseup", t4, this.lastTouches[0], document), this.hasMoved || this.dispatchRelatedMouseEvent("click", t4, this.lastTouches[0])), this.movingTimeout && (this.isMoving = false, clearTimeout(this.movingTimeout)), this.touchMode) {
                  case 2:
                    if (1 === t4.touches.length) {
                      this.handleStart(t4), t4.preventDefault();
                      break;
                    }
                  case 1:
                    if (this.isMoving) {
                      var e4 = this.renderer.getCamera(), r3 = e4.getState(), i3 = e4.getPreviousState() || { x: 0, y: 0 };
                      e4.animate({ x: r3.x + 3 * (r3.x - i3.x), y: r3.y + 3 * (r3.y - i3.y) }, { duration: 200, easing: "quadraticOut" });
                    }
                    this.hasMoved = false, this.isMoving = false, this.touchMode = 0;
                }
                this.emit("touchup", (0, l.getTouchCoords)(t4, this.container));
              }
            }, e3.prototype.handleMove = function(t4) {
              var e4, r3 = this;
              if (this.enabled) {
                t4.preventDefault(), 1 === t4.touches.length && this.dispatchRelatedMouseEvent("mousemove", t4);
                var i3 = (0, l.getTouchesArray)(t4.touches), n2 = i3.map(function(t5) {
                  return (0, l.getPosition)(t5, r3.container);
                });
                if (this.lastTouches = i3, this.lastTouchesPositions = n2, this.hasMoved || (this.hasMoved = n2.some(function(t5, e5) {
                  var i4 = r3.startTouchesPositions[e5];
                  return t5.x !== i4.x || t5.y !== i4.y;
                })), this.hasMoved) {
                  this.isMoving = true, this.movingTimeout && clearTimeout(this.movingTimeout), this.movingTimeout = window.setTimeout(function() {
                    r3.isMoving = false;
                  }, 200);
                  var o2 = this.renderer.getCamera(), a2 = this.startCameraState;
                  switch (this.touchMode) {
                    case 1:
                      var s2 = this.renderer.viewportToFramedGraph((this.startTouchesPositions || [])[0]), c2 = s2.x, u = s2.y, d = this.renderer.viewportToFramedGraph(n2[0]), f = d.x, p = d.y;
                      o2.setState({ x: a2.x + c2 - f, y: a2.y + u - p });
                      break;
                    case 2:
                      var g = {}, v = n2[0], m = v.x, y = v.y, b = n2[1], _ = b.x, x = b.y, w = Math.atan2(x - y, _ - m) - this.startTouchesAngle, E = Math.hypot(x - y, _ - m) / this.startTouchesDistance, L = o2.getBoundedRatio(a2.ratio / E);
                      g.ratio = L, g.angle = a2.angle + w;
                      var F = this.getDimensions(), C = this.renderer.viewportToFramedGraph((this.startTouchesPositions || [])[0], { cameraState: a2 }), A = Math.min(F.width, F.height), T = A / F.width, P = L / A;
                      p = y - A / 2 / (A / F.height), f = (e4 = h([(f = m - A / 2 / T) * Math.cos(-g.angle) - p * Math.sin(-g.angle), p * Math.cos(-g.angle) + f * Math.sin(-g.angle)], 2))[0], p = e4[1], g.x = C.x - f * P, g.y = C.y + p * P, o2.setState(g);
                  }
                  this.emit("touchmove", (0, l.getTouchCoords)(t4, this.container));
                }
              }
            }, e3;
          }(l.default);
          e2.default = c;
        }, 730: (t2, e2) => {
          "use strict";
          Object.defineProperty(e2, "__esModule", { value: true }), e2.edgeLabelsToDisplayFromNodes = e2.LabelGrid = void 0;
          var r2 = function() {
            function t3(t4, e3) {
              this.key = t4, this.size = e3;
            }
            return t3.compare = function(t4, e3) {
              return t4.size > e3.size ? -1 : t4.size < e3.size || t4.key > e3.key ? 1 : -1;
            }, t3;
          }(), i2 = function() {
            function t3() {
              this.width = 0, this.height = 0, this.cellSize = 0, this.columns = 0, this.rows = 0, this.cells = {};
            }
            return t3.prototype.resizeAndClear = function(t4, e3) {
              this.width = t4.width, this.height = t4.height, this.cellSize = e3, this.columns = Math.ceil(t4.width / e3), this.rows = Math.ceil(t4.height / e3), this.cells = {};
            }, t3.prototype.getIndex = function(t4) {
              var e3 = Math.floor(t4.x / this.cellSize);
              return Math.floor(t4.y / this.cellSize) * this.columns + e3;
            }, t3.prototype.add = function(t4, e3, i3) {
              var n = new r2(t4, e3), o = this.getIndex(i3), a = this.cells[o];
              a || (a = [], this.cells[o] = a), a.push(n);
            }, t3.prototype.organize = function() {
              for (var t4 in this.cells) this.cells[t4].sort(r2.compare);
            }, t3.prototype.getLabelsToDisplay = function(t4, e3) {
              var r3 = this.cellSize * this.cellSize, i3 = r3 / t4 / t4 * e3 / r3, n = Math.ceil(i3), o = [];
              for (var a in this.cells) for (var s = this.cells[a], h = 0; h < Math.min(n, s.length); h++) o.push(s[h].key);
              return o;
            }, t3;
          }();
          e2.LabelGrid = i2, e2.edgeLabelsToDisplayFromNodes = function(t3) {
            var e3 = t3.graph, r3 = t3.hoveredNode, i3 = t3.highlightedNodes, n = t3.displayedNodeLabels, o = [];
            return e3.forEachEdge(function(t4, e4, a, s) {
              (a === r3 || s === r3 || i3.has(a) || i3.has(s) || n.has(a) && n.has(s)) && o.push(t4);
            }), o;
          };
        }, 134: function(t2, e2, r2) {
          "use strict";
          var i2 = this && this.__importDefault || function(t3) {
            return t3 && t3.__esModule ? t3 : { default: t3 };
          };
          Object.defineProperty(e2, "__esModule", { value: true }), e2.rectangleCollidesWithQuad = e2.squareCollidesWithQuad = e2.getCircumscribedAlignedRectangle = e2.isRectangleAligned = void 0;
          var n = i2(r2(796)), o = false;
          function a(t3) {
            return t3.x1 === t3.x2 || t3.y1 === t3.y2;
          }
          function s(t3) {
            var e3 = Math.sqrt(Math.pow(t3.x2 - t3.x1, 2) + Math.pow(t3.y2 - t3.y1, 2)), r3 = (t3.y1 - t3.y2) * t3.height / e3, i3 = (t3.x2 - t3.x1) * t3.height / e3, n2 = { x: t3.x1, y: t3.y1 }, o2 = { x: t3.x2, y: t3.y2 }, a2 = { x: t3.x1 + r3, y: t3.y1 + i3 }, s2 = { x: t3.x2 + r3, y: t3.y2 + i3 }, h2 = Math.min(n2.x, o2.x, a2.x, s2.x), l2 = Math.max(n2.x, o2.x, a2.x, s2.x), c2 = Math.min(n2.y, o2.y, a2.y, s2.y);
            return { x1: h2, y1: c2, x2: l2, y2: c2, height: Math.max(n2.y, o2.y, a2.y, s2.y) - c2 };
          }
          function h(t3, e3, r3, i3, n2, o2, a2) {
            return t3 < i3 + o2 && t3 + r3 > i3 && e3 < n2 + a2 && e3 + r3 > n2;
          }
          function l(t3, e3, r3, i3, n2, o2, a2, s2) {
            return t3 < n2 + a2 && t3 + r3 > n2 && e3 < o2 + s2 && e3 + i3 > o2;
          }
          function c(t3, e3, r3, i3, n2, o2) {
            var a2 = t3 < r3 + n2 / 2;
            return e3 < i3 + o2 / 2 ? a2 ? 1 : 2 : a2 ? 3 : 4;
          }
          e2.isRectangleAligned = a, e2.getCircumscribedAlignedRectangle = s, e2.squareCollidesWithQuad = h, e2.rectangleCollidesWithQuad = l;
          var u = function() {
            function t3(t4) {
              var e3;
              void 0 === t4 && (t4 = {}), this.containers = ((e3 = {})[5460] = [], e3), this.cache = null, this.lastRectangle = null;
              var r3 = Math.pow(4, 5);
              this.data = new Float32Array((4 * r3 - 1) / 3 * 4), t4.boundaries ? this.resize(t4.boundaries) : this.resize({ x: 0, y: 0, width: 1, height: 1 });
            }
            return t3.prototype.add = function(t4, e3, r3, i3) {
              return function(t5, e4, r4, i4, n2, a2, s2) {
                for (var l2 = n2 - s2, c2 = a2 - s2, u2 = 2 * s2, d = 0, f = 0; ; ) {
                  if (d >= 5) return r4[f] = r4[f] || [], void r4[f].push(i4);
                  var p = 4 * f + 4, g = 4 * f + 8, v = 4 * f + 12, m = 4 * f + 16, y = h(l2, c2, u2, e4[p + 0], e4[p + 1], e4[p + 2], e4[p + 3]), b = h(l2, c2, u2, e4[g + 0], e4[g + 1], e4[g + 2], e4[g + 3]), _ = h(l2, c2, u2, e4[v + 0], e4[v + 1], e4[v + 2], e4[v + 3]), x = h(l2, c2, u2, e4[m + 0], e4[m + 1], e4[m + 2], e4[m + 3]), w = [y, b, _, x].reduce(function(t6, e5) {
                    return e5 ? t6 + 1 : t6;
                  }, 0);
                  if (0 === w && 0 === d) return r4[5460].push(i4), void (!o && r4[5460].length >= 5 && (o = true, console.warn("sigma/quadtree.insertNode: At least 5 nodes are outside the global quadtree zone. You might have a problem with the normalization function or the custom bounding box.")));
                  if (0 === w) throw new Error("sigma/quadtree.insertNode: no collision (level: ".concat(d, ", key: ").concat(i4, ", x: ").concat(n2, ", y: ").concat(a2, ", size: ").concat(s2, ")."));
                  if (3 === w) throw new Error("sigma/quadtree.insertNode: 3 impossible collisions (level: ".concat(d, ", key: ").concat(i4, ", x: ").concat(n2, ", y: ").concat(a2, ", size: ").concat(s2, ")."));
                  if (w > 1) return r4[f] = r4[f] || [], void r4[f].push(i4);
                  d++, y && (f = p), b && (f = g), _ && (f = v), x && (f = m);
                }
              }(0, this.data, this.containers, t4, e3, r3, i3), this;
            }, t3.prototype.resize = function(t4) {
              this.clear(), this.data[0] = t4.x, this.data[1] = t4.y, this.data[2] = t4.width, this.data[3] = t4.height, function(t5, e3) {
                for (var r3 = [0, 0]; r3.length; ) {
                  var i3 = r3.pop(), n2 = r3.pop(), o2 = 4 * n2 + 4, a2 = 4 * n2 + 8, s2 = 4 * n2 + 12, h2 = 4 * n2 + 16, l2 = e3[n2 + 0], c2 = e3[n2 + 1], u2 = e3[n2 + 2] / 2, d = e3[n2 + 3] / 2;
                  e3[o2 + 0] = l2, e3[o2 + 1] = c2, e3[o2 + 2] = u2, e3[o2 + 3] = d, e3[a2 + 0] = l2 + u2, e3[a2 + 1] = c2, e3[a2 + 2] = u2, e3[a2 + 3] = d, e3[s2 + 0] = l2, e3[s2 + 1] = c2 + d, e3[s2 + 2] = u2, e3[s2 + 3] = d, e3[h2 + 0] = l2 + u2, e3[h2 + 1] = c2 + d, e3[h2 + 2] = u2, e3[h2 + 3] = d, i3 < 4 && (r3.push(h2, i3 + 1), r3.push(s2, i3 + 1), r3.push(a2, i3 + 1), r3.push(o2, i3 + 1));
                }
              }(0, this.data);
            }, t3.prototype.clear = function() {
              var t4;
              return this.containers = ((t4 = {})[5460] = [], t4), this;
            }, t3.prototype.point = function(t4, e3) {
              var r3 = this.containers[5460].slice(), i3 = 0, o2 = 0;
              do {
                this.containers[i3] && (0, n.default)(r3, this.containers[i3]), i3 = 4 * i3 + 4 * c(t4, e3, this.data[i3 + 0], this.data[i3 + 1], this.data[i3 + 2], this.data[i3 + 3]), o2++;
              } while (o2 <= 5);
              return r3;
            }, t3.prototype.rectangle = function(t4, e3, r3, i3, o2) {
              var h2 = this.lastRectangle;
              return h2 && t4 === h2.x1 && r3 === h2.x2 && e3 === h2.y1 && i3 === h2.y2 && o2 === h2.height || (this.lastRectangle = { x1: t4, y1: e3, x2: r3, y2: i3, height: o2 }, a(this.lastRectangle) || (this.lastRectangle = s(this.lastRectangle)), this.cache = function(t5, e4, r4, i4, o3, a2, s2) {
                for (var h3, c2 = [0, 0], u2 = []; c2.length; ) {
                  var d = c2.pop(), f = c2.pop();
                  if ((h3 = r4[f]) && (0, n.default)(u2, h3), !(d >= 5)) {
                    var p = 4 * f + 4, g = 4 * f + 8, v = 4 * f + 12, m = 4 * f + 16, y = l(i4, o3, a2, s2, e4[p + 0], e4[p + 1], e4[p + 2], e4[p + 3]), b = l(i4, o3, a2, s2, e4[g + 0], e4[g + 1], e4[g + 2], e4[g + 3]), _ = l(i4, o3, a2, s2, e4[v + 0], e4[v + 1], e4[v + 2], e4[v + 3]), x = l(i4, o3, a2, s2, e4[m + 0], e4[m + 1], e4[m + 2], e4[m + 3]);
                    y && c2.push(p, d + 1), b && c2.push(g, d + 1), _ && c2.push(v, d + 1), x && c2.push(m, d + 1);
                  }
                }
                return u2;
              }(0, this.data, this.containers, t4, e3, Math.abs(t4 - r3) || Math.abs(e3 - i3), o2), (0, n.default)(this.cache, this.containers[5460])), this.cache;
            }, t3;
          }();
          e2.default = u;
        }, 265: function(t2, e2, r2) {
          "use strict";
          var i2, n = this && this.__extends || (i2 = function(t3, e3) {
            return i2 = Object.setPrototypeOf || { __proto__: [] } instanceof Array && function(t4, e4) {
              t4.__proto__ = e4;
            } || function(t4, e4) {
              for (var r3 in e4) Object.prototype.hasOwnProperty.call(e4, r3) && (t4[r3] = e4[r3]);
            }, i2(t3, e3);
          }, function(t3, e3) {
            if ("function" != typeof e3 && null !== e3) throw new TypeError("Class extends value " + String(e3) + " is not a constructor or null");
            function r3() {
              this.constructor = t3;
            }
            i2(t3, e3), t3.prototype = null === e3 ? Object.create(e3) : (r3.prototype = e3.prototype, new r3());
          }), o = this && this.__importDefault || function(t3) {
            return t3 && t3.__esModule ? t3 : { default: t3 };
          };
          Object.defineProperty(e2, "__esModule", { value: true });
          var a = o(r2(159)), s = o(r2(764)), h = o(r2(134)), l = o(r2(269)), c = function(t3) {
            function e3() {
              return null !== t3 && t3.apply(this, arguments) || this;
            }
            return n(e3, t3), e3.Camera = s.default, e3.QuadTree = h.default, e3.MouseCaptor = l.default, e3.Sigma = a.default, e3;
          }(a.default);
          t2.exports = c;
        }, 942: (t2, e2) => {
          "use strict";
          Object.defineProperty(e2, "__esModule", { value: true }), e2.default = function(t3, e3, r2, i2, n) {
            var o = n.edgeLabelSize, a = n.edgeLabelFont, s = n.edgeLabelWeight, h = n.edgeLabelColor.attribute ? e3[n.edgeLabelColor.attribute] || n.edgeLabelColor.color || "#000" : n.edgeLabelColor.color, l = e3.label;
            if (l) {
              t3.fillStyle = h, t3.font = "".concat(s, " ").concat(o, "px ").concat(a);
              var c, u, d = r2.size, f = i2.size, p = r2.x, g = r2.y, v = i2.x, m = i2.y, y = v - p, b = m - g, _ = Math.sqrt(y * y + b * b);
              if (!(_ < d + f)) {
                c = ((p += y * d / _) + (v -= y * f / _)) / 2, u = ((g += b * d / _) + (m -= b * f / _)) / 2, y = v - p, b = m - g, _ = Math.sqrt(y * y + b * b);
                var x, w = t3.measureText(l).width;
                if (w > _) {
                  for (l += "\u2026", w = t3.measureText(l).width; w > _ && l.length > 1; ) l = l.slice(0, -2) + "\u2026", w = t3.measureText(l).width;
                  if (l.length < 4) return;
                }
                x = y > 0 ? b > 0 ? Math.acos(y / _) : Math.asin(b / _) : b > 0 ? Math.acos(y / _) + Math.PI : Math.asin(y / _) + Math.PI / 2, t3.save(), t3.translate(c, u), t3.rotate(x), t3.fillText(l, -w / 2, e3.size / 2 + o), t3.restore();
              }
            }
          };
        }, 61: function(t2, e2, r2) {
          "use strict";
          var i2 = this && this.__importDefault || function(t3) {
            return t3 && t3.__esModule ? t3 : { default: t3 };
          };
          Object.defineProperty(e2, "__esModule", { value: true });
          var n = i2(r2(622));
          e2.default = function(t3, e3, r3) {
            var i3 = r3.labelSize, o = r3.labelFont, a = r3.labelWeight;
            if (t3.font = "".concat(a, " ").concat(i3, "px ").concat(o), t3.fillStyle = "#FFF", t3.shadowOffsetX = 0, t3.shadowOffsetY = 0, t3.shadowBlur = 8, t3.shadowColor = "#000", "string" == typeof e3.label) {
              var s = t3.measureText(e3.label).width, h = Math.round(s + 5), l = Math.round(i3 + 4), c = Math.max(e3.size, i3 / 2) + 2, u = Math.asin(l / 2 / c), d = Math.sqrt(Math.abs(Math.pow(c, 2) - Math.pow(l / 2, 2)));
              t3.beginPath(), t3.moveTo(e3.x + d, e3.y + l / 2), t3.lineTo(e3.x + c + h, e3.y + l / 2), t3.lineTo(e3.x + c + h, e3.y - l / 2), t3.lineTo(e3.x + d, e3.y - l / 2), t3.arc(e3.x, e3.y, c, u, -u), t3.closePath(), t3.fill();
            } else t3.beginPath(), t3.arc(e3.x, e3.y, e3.size + 2, 0, 2 * Math.PI), t3.closePath(), t3.fill();
            t3.shadowOffsetX = 0, t3.shadowOffsetY = 0, t3.shadowBlur = 0, (0, n.default)(t3, e3, r3);
          };
        }, 622: (t2, e2) => {
          "use strict";
          Object.defineProperty(e2, "__esModule", { value: true }), e2.default = function(t3, e3, r2) {
            if (e3.label) {
              var i2 = r2.labelSize, n = r2.labelFont, o = r2.labelWeight, a = r2.labelColor.attribute ? e3[r2.labelColor.attribute] || r2.labelColor.color || "#000" : r2.labelColor.color;
              t3.fillStyle = a, t3.font = "".concat(o, " ").concat(i2, "px ").concat(n), t3.fillText(e3.label, e3.x + e3.size + 3, e3.y + i2 / 3);
            }
          };
        }, 195: function(t2, e2, r2) {
          "use strict";
          var i2, n = this && this.__extends || (i2 = function(t3, e3) {
            return i2 = Object.setPrototypeOf || { __proto__: [] } instanceof Array && function(t4, e4) {
              t4.__proto__ = e4;
            } || function(t4, e4) {
              for (var r3 in e4) Object.prototype.hasOwnProperty.call(e4, r3) && (t4[r3] = e4[r3]);
            }, i2(t3, e3);
          }, function(t3, e3) {
            if ("function" != typeof e3 && null !== e3) throw new TypeError("Class extends value " + String(e3) + " is not a constructor or null");
            function r3() {
              this.constructor = t3;
            }
            i2(t3, e3), t3.prototype = null === e3 ? Object.create(e3) : (r3.prototype = e3.prototype, new r3());
          });
          Object.defineProperty(e2, "__esModule", { value: true }), e2.createEdgeCompoundProgram = e2.AbstractEdgeProgram = void 0;
          var o = function(t3) {
            function e3(e4, r3, i3, n2, o2) {
              return t3.call(this, e4, r3, i3, n2, o2) || this;
            }
            return n(e3, t3), e3;
          }(r2(171).AbstractProgram);
          e2.AbstractEdgeProgram = o, e2.createEdgeCompoundProgram = function(t3) {
            return function() {
              function e3(e4, r3) {
                this.programs = t3.map(function(t4) {
                  return new t4(e4, r3);
                });
              }
              return e3.prototype.bufferData = function() {
                this.programs.forEach(function(t4) {
                  return t4.bufferData();
                });
              }, e3.prototype.allocate = function(t4) {
                this.programs.forEach(function(e4) {
                  return e4.allocate(t4);
                });
              }, e3.prototype.bind = function() {
              }, e3.prototype.computeIndices = function() {
                this.programs.forEach(function(t4) {
                  return t4.computeIndices();
                });
              }, e3.prototype.render = function(t4) {
                this.programs.forEach(function(e4) {
                  e4.bind(), e4.bufferData(), e4.render(t4);
                });
              }, e3.prototype.process = function(t4, e4, r3, i3, n2) {
                this.programs.forEach(function(o2) {
                  return o2.process(t4, e4, r3, i3, n2);
                });
              }, e3;
            }();
          };
        }, 909: function(t2, e2, r2) {
          "use strict";
          var i2, n = this && this.__extends || (i2 = function(t3, e3) {
            return i2 = Object.setPrototypeOf || { __proto__: [] } instanceof Array && function(t4, e4) {
              t4.__proto__ = e4;
            } || function(t4, e4) {
              for (var r3 in e4) Object.prototype.hasOwnProperty.call(e4, r3) && (t4[r3] = e4[r3]);
            }, i2(t3, e3);
          }, function(t3, e3) {
            if ("function" != typeof e3 && null !== e3) throw new TypeError("Class extends value " + String(e3) + " is not a constructor or null");
            function r3() {
              this.constructor = t3;
            }
            i2(t3, e3), t3.prototype = null === e3 ? Object.create(e3) : (r3.prototype = e3.prototype, new r3());
          });
          Object.defineProperty(e2, "__esModule", { value: true }), e2.createNodeCompoundProgram = e2.AbstractNodeProgram = void 0;
          var o = function(t3) {
            function e3(e4, r3, i3, n2, o2) {
              var a = t3.call(this, e4, r3, i3, n2, o2) || this;
              a.positionLocation = e4.getAttribLocation(a.program, "a_position"), a.sizeLocation = e4.getAttribLocation(a.program, "a_size"), a.colorLocation = e4.getAttribLocation(a.program, "a_color");
              var s = e4.getUniformLocation(a.program, "u_matrix");
              if (null === s) throw new Error("AbstractNodeProgram: error while getting matrixLocation");
              a.matrixLocation = s;
              var h = e4.getUniformLocation(a.program, "u_ratio");
              if (null === h) throw new Error("AbstractNodeProgram: error while getting ratioLocation");
              a.ratioLocation = h;
              var l = e4.getUniformLocation(a.program, "u_scale");
              if (null === l) throw new Error("AbstractNodeProgram: error while getting scaleLocation");
              return a.scaleLocation = l, a;
            }
            return n(e3, t3), e3.prototype.bind = function() {
              var t4 = this.gl;
              t4.enableVertexAttribArray(this.positionLocation), t4.enableVertexAttribArray(this.sizeLocation), t4.enableVertexAttribArray(this.colorLocation), t4.vertexAttribPointer(this.positionLocation, 2, t4.FLOAT, false, this.attributes * Float32Array.BYTES_PER_ELEMENT, 0), t4.vertexAttribPointer(this.sizeLocation, 1, t4.FLOAT, false, this.attributes * Float32Array.BYTES_PER_ELEMENT, 8), t4.vertexAttribPointer(this.colorLocation, 4, t4.UNSIGNED_BYTE, true, this.attributes * Float32Array.BYTES_PER_ELEMENT, 12);
            }, e3;
          }(r2(171).AbstractProgram);
          e2.AbstractNodeProgram = o, e2.createNodeCompoundProgram = function(t3) {
            return function() {
              function e3(e4, r3) {
                this.programs = t3.map(function(t4) {
                  return new t4(e4, r3);
                });
              }
              return e3.prototype.bufferData = function() {
                this.programs.forEach(function(t4) {
                  return t4.bufferData();
                });
              }, e3.prototype.allocate = function(t4) {
                this.programs.forEach(function(e4) {
                  return e4.allocate(t4);
                });
              }, e3.prototype.bind = function() {
              }, e3.prototype.render = function(t4) {
                this.programs.forEach(function(e4) {
                  e4.bind(), e4.bufferData(), e4.render(t4);
                });
              }, e3.prototype.process = function(t4, e4, r3) {
                this.programs.forEach(function(i3) {
                  return i3.process(t4, e4, r3);
                });
              }, e3;
            }();
          };
        }, 171: (t2, e2, r2) => {
          "use strict";
          Object.defineProperty(e2, "__esModule", { value: true }), e2.AbstractProgram = void 0;
          var i2 = r2(706), n = function() {
            function t3(t4, e3, r3, n2, o) {
              this.array = new Float32Array(), this.points = n2, this.attributes = o, this.gl = t4, this.vertexShaderSource = e3, this.fragmentShaderSource = r3;
              var a = t4.createBuffer();
              if (null === a) throw new Error("AbstractProgram: error while creating the buffer");
              this.buffer = a, t4.bindBuffer(t4.ARRAY_BUFFER, this.buffer), this.vertexShader = (0, i2.loadVertexShader)(t4, this.vertexShaderSource), this.fragmentShader = (0, i2.loadFragmentShader)(t4, this.fragmentShaderSource), this.program = (0, i2.loadProgram)(t4, [this.vertexShader, this.fragmentShader]);
            }
            return t3.prototype.bufferData = function() {
              var t4 = this.gl;
              t4.bufferData(t4.ARRAY_BUFFER, this.array, t4.DYNAMIC_DRAW);
            }, t3.prototype.allocate = function(t4) {
              this.array = new Float32Array(this.points * this.attributes * t4);
            }, t3.prototype.hasNothingToRender = function() {
              return 0 === this.array.length;
            }, t3;
          }();
          e2.AbstractProgram = n;
        }, 569: function(t2, e2, r2) {
          "use strict";
          var i2 = this && this.__importDefault || function(t3) {
            return t3 && t3.__esModule ? t3 : { default: t3 };
          };
          Object.defineProperty(e2, "__esModule", { value: true });
          var n = r2(195), o = i2(r2(805)), a = i2(r2(483)), s = (0, n.createEdgeCompoundProgram)([a.default, o.default]);
          e2.default = s;
        }, 805: function(t2, e2, r2) {
          "use strict";
          var i2, n = this && this.__extends || (i2 = function(t3, e3) {
            return i2 = Object.setPrototypeOf || { __proto__: [] } instanceof Array && function(t4, e4) {
              t4.__proto__ = e4;
            } || function(t4, e4) {
              for (var r3 in e4) Object.prototype.hasOwnProperty.call(e4, r3) && (t4[r3] = e4[r3]);
            }, i2(t3, e3);
          }, function(t3, e3) {
            if ("function" != typeof e3 && null !== e3) throw new TypeError("Class extends value " + String(e3) + " is not a constructor or null");
            function r3() {
              this.constructor = t3;
            }
            i2(t3, e3), t3.prototype = null === e3 ? Object.create(e3) : (r3.prototype = e3.prototype, new r3());
          }), o = this && this.__importDefault || function(t3) {
            return t3 && t3.__esModule ? t3 : { default: t3 };
          };
          Object.defineProperty(e2, "__esModule", { value: true });
          var a = r2(928), s = o(r2(912)), h = o(r2(973)), l = function(t3) {
            function e3(e4) {
              var r3 = t3.call(this, e4, s.default, h.default, 3, 9) || this;
              r3.positionLocation = e4.getAttribLocation(r3.program, "a_position"), r3.colorLocation = e4.getAttribLocation(r3.program, "a_color"), r3.normalLocation = e4.getAttribLocation(r3.program, "a_normal"), r3.radiusLocation = e4.getAttribLocation(r3.program, "a_radius"), r3.barycentricLocation = e4.getAttribLocation(r3.program, "a_barycentric");
              var i3 = e4.getUniformLocation(r3.program, "u_matrix");
              if (null === i3) throw new Error("EdgeArrowHeadProgram: error while getting matrixLocation");
              r3.matrixLocation = i3;
              var n2 = e4.getUniformLocation(r3.program, "u_sqrtZoomRatio");
              if (null === n2) throw new Error("EdgeArrowHeadProgram: error while getting sqrtZoomRatioLocation");
              r3.sqrtZoomRatioLocation = n2;
              var o2 = e4.getUniformLocation(r3.program, "u_correctionRatio");
              if (null === o2) throw new Error("EdgeArrowHeadProgram: error while getting correctionRatioLocation");
              return r3.correctionRatioLocation = o2, r3.bind(), r3;
            }
            return n(e3, t3), e3.prototype.bind = function() {
              var t4 = this.gl;
              t4.enableVertexAttribArray(this.positionLocation), t4.enableVertexAttribArray(this.normalLocation), t4.enableVertexAttribArray(this.radiusLocation), t4.enableVertexAttribArray(this.colorLocation), t4.enableVertexAttribArray(this.barycentricLocation), t4.vertexAttribPointer(this.positionLocation, 2, t4.FLOAT, false, 9 * Float32Array.BYTES_PER_ELEMENT, 0), t4.vertexAttribPointer(this.normalLocation, 2, t4.FLOAT, false, 9 * Float32Array.BYTES_PER_ELEMENT, 8), t4.vertexAttribPointer(this.radiusLocation, 1, t4.FLOAT, false, 9 * Float32Array.BYTES_PER_ELEMENT, 16), t4.vertexAttribPointer(this.colorLocation, 4, t4.UNSIGNED_BYTE, true, 9 * Float32Array.BYTES_PER_ELEMENT, 20), t4.vertexAttribPointer(this.barycentricLocation, 3, t4.FLOAT, false, 9 * Float32Array.BYTES_PER_ELEMENT, 24);
            }, e3.prototype.computeIndices = function() {
            }, e3.prototype.process = function(t4, e4, r3, i3, n2) {
              if (i3) for (var o2 = 27 * n2, s2 = o2 + 27; o2 < s2; o2++) this.array[o2] = 0;
              else {
                var h2 = r3.size || 1, l2 = e4.size || 1, c = t4.x, u = t4.y, d = e4.x, f = e4.y, p = (0, a.floatColor)(r3.color), g = d - c, v = f - u, m = g * g + v * v, y = 0, b = 0;
                m && (y = -v * (m = 1 / Math.sqrt(m)) * h2, b = g * m * h2);
                var _ = 27 * n2, x = this.array;
                x[_++] = d, x[_++] = f, x[_++] = -y, x[_++] = -b, x[_++] = l2, x[_++] = p, x[_++] = 1, x[_++] = 0, x[_++] = 0, x[_++] = d, x[_++] = f, x[_++] = -y, x[_++] = -b, x[_++] = l2, x[_++] = p, x[_++] = 0, x[_++] = 1, x[_++] = 0, x[_++] = d, x[_++] = f, x[_++] = -y, x[_++] = -b, x[_++] = l2, x[_++] = p, x[_++] = 0, x[_++] = 0, x[_] = 1;
              }
            }, e3.prototype.render = function(t4) {
              if (!this.hasNothingToRender()) {
                var e4 = this.gl, r3 = this.program;
                e4.useProgram(r3), e4.uniformMatrix3fv(this.matrixLocation, false, t4.matrix), e4.uniform1f(this.sqrtZoomRatioLocation, Math.sqrt(t4.ratio)), e4.uniform1f(this.correctionRatioLocation, t4.correctionRatio), e4.drawArrays(e4.TRIANGLES, 0, this.array.length / 9);
              }
            }, e3;
          }(r2(195).AbstractEdgeProgram);
          e2.default = l;
        }, 483: function(t2, e2, r2) {
          "use strict";
          var i2, n = this && this.__extends || (i2 = function(t3, e3) {
            return i2 = Object.setPrototypeOf || { __proto__: [] } instanceof Array && function(t4, e4) {
              t4.__proto__ = e4;
            } || function(t4, e4) {
              for (var r3 in e4) Object.prototype.hasOwnProperty.call(e4, r3) && (t4[r3] = e4[r3]);
            }, i2(t3, e3);
          }, function(t3, e3) {
            if ("function" != typeof e3 && null !== e3) throw new TypeError("Class extends value " + String(e3) + " is not a constructor or null");
            function r3() {
              this.constructor = t3;
            }
            i2(t3, e3), t3.prototype = null === e3 ? Object.create(e3) : (r3.prototype = e3.prototype, new r3());
          }), o = this && this.__importDefault || function(t3) {
            return t3 && t3.__esModule ? t3 : { default: t3 };
          };
          Object.defineProperty(e2, "__esModule", { value: true });
          var a = r2(195), s = r2(928), h = o(r2(620)), l = o(r2(498)), c = function(t3) {
            function e3(e4) {
              var r3 = t3.call(this, e4, h.default, l.default, 4, 6) || this, i3 = e4.createBuffer();
              if (null === i3) throw new Error("EdgeClampedProgram: error while getting resolutionLocation");
              r3.indicesBuffer = i3, r3.positionLocation = e4.getAttribLocation(r3.program, "a_position"), r3.colorLocation = e4.getAttribLocation(r3.program, "a_color"), r3.normalLocation = e4.getAttribLocation(r3.program, "a_normal"), r3.radiusLocation = e4.getAttribLocation(r3.program, "a_radius");
              var n2 = e4.getUniformLocation(r3.program, "u_matrix");
              if (null === n2) throw new Error("EdgeClampedProgram: error while getting matrixLocation");
              r3.matrixLocation = n2;
              var o2 = e4.getUniformLocation(r3.program, "u_sqrtZoomRatio");
              if (null === o2) throw new Error("EdgeClampedProgram: error while getting cameraRatioLocation");
              r3.sqrtZoomRatioLocation = o2;
              var a2 = e4.getUniformLocation(r3.program, "u_correctionRatio");
              if (null === a2) throw new Error("EdgeClampedProgram: error while getting viewportRatioLocation");
              return r3.correctionRatioLocation = a2, r3.canUse32BitsIndices = (0, s.canUse32BitsIndices)(e4), r3.IndicesArray = r3.canUse32BitsIndices ? Uint32Array : Uint16Array, r3.indicesArray = new r3.IndicesArray(), r3.indicesType = r3.canUse32BitsIndices ? e4.UNSIGNED_INT : e4.UNSIGNED_SHORT, r3.bind(), r3;
            }
            return n(e3, t3), e3.prototype.bind = function() {
              var t4 = this.gl;
              t4.bindBuffer(t4.ELEMENT_ARRAY_BUFFER, this.indicesBuffer), t4.enableVertexAttribArray(this.positionLocation), t4.enableVertexAttribArray(this.normalLocation), t4.enableVertexAttribArray(this.colorLocation), t4.enableVertexAttribArray(this.radiusLocation), t4.vertexAttribPointer(this.positionLocation, 2, t4.FLOAT, false, 6 * Float32Array.BYTES_PER_ELEMENT, 0), t4.vertexAttribPointer(this.normalLocation, 2, t4.FLOAT, false, 6 * Float32Array.BYTES_PER_ELEMENT, 8), t4.vertexAttribPointer(this.colorLocation, 4, t4.UNSIGNED_BYTE, true, 6 * Float32Array.BYTES_PER_ELEMENT, 16), t4.vertexAttribPointer(this.radiusLocation, 1, t4.FLOAT, false, 6 * Float32Array.BYTES_PER_ELEMENT, 20);
            }, e3.prototype.process = function(t4, e4, r3, i3, n2) {
              if (i3) for (var o2 = 24 * n2, a2 = o2 + 24; o2 < a2; o2++) this.array[o2] = 0;
              else {
                var h2 = r3.size || 1, l2 = t4.x, c2 = t4.y, u = e4.x, d = e4.y, f = e4.size || 1, p = (0, s.floatColor)(r3.color), g = u - l2, v = d - c2, m = g * g + v * v, y = 0, b = 0;
                m && (y = -v * (m = 1 / Math.sqrt(m)) * h2, b = g * m * h2);
                var _ = 24 * n2, x = this.array;
                x[_++] = l2, x[_++] = c2, x[_++] = y, x[_++] = b, x[_++] = p, x[_++] = 0, x[_++] = l2, x[_++] = c2, x[_++] = -y, x[_++] = -b, x[_++] = p, x[_++] = 0, x[_++] = u, x[_++] = d, x[_++] = y, x[_++] = b, x[_++] = p, x[_++] = f, x[_++] = u, x[_++] = d, x[_++] = -y, x[_++] = -b, x[_++] = p, x[_] = -f;
              }
            }, e3.prototype.computeIndices = function() {
              for (var t4 = this.array.length / 6, e4 = t4 + t4 / 2, r3 = new this.IndicesArray(e4), i3 = 0, n2 = 0; i3 < t4; i3 += 4) r3[n2++] = i3, r3[n2++] = i3 + 1, r3[n2++] = i3 + 2, r3[n2++] = i3 + 2, r3[n2++] = i3 + 1, r3[n2++] = i3 + 3;
              this.indicesArray = r3;
            }, e3.prototype.bufferData = function() {
              t3.prototype.bufferData.call(this);
              var e4 = this.gl;
              e4.bufferData(e4.ELEMENT_ARRAY_BUFFER, this.indicesArray, e4.STATIC_DRAW);
            }, e3.prototype.render = function(t4) {
              if (!this.hasNothingToRender()) {
                var e4 = this.gl, r3 = this.program;
                e4.useProgram(r3), e4.uniformMatrix3fv(this.matrixLocation, false, t4.matrix), e4.uniform1f(this.sqrtZoomRatioLocation, Math.sqrt(t4.ratio)), e4.uniform1f(this.correctionRatioLocation, t4.correctionRatio), e4.drawElements(e4.TRIANGLES, this.indicesArray.length, this.indicesType, 0);
              }
            }, e3;
          }(a.AbstractEdgeProgram);
          e2.default = c;
        }, 753: function(t2, e2, r2) {
          "use strict";
          var i2, n = this && this.__extends || (i2 = function(t3, e3) {
            return i2 = Object.setPrototypeOf || { __proto__: [] } instanceof Array && function(t4, e4) {
              t4.__proto__ = e4;
            } || function(t4, e4) {
              for (var r3 in e4) Object.prototype.hasOwnProperty.call(e4, r3) && (t4[r3] = e4[r3]);
            }, i2(t3, e3);
          }, function(t3, e3) {
            if ("function" != typeof e3 && null !== e3) throw new TypeError("Class extends value " + String(e3) + " is not a constructor or null");
            function r3() {
              this.constructor = t3;
            }
            i2(t3, e3), t3.prototype = null === e3 ? Object.create(e3) : (r3.prototype = e3.prototype, new r3());
          }), o = this && this.__importDefault || function(t3) {
            return t3 && t3.__esModule ? t3 : { default: t3 };
          };
          Object.defineProperty(e2, "__esModule", { value: true });
          var a = r2(928), s = o(r2(223)), h = o(r2(498)), l = function(t3) {
            function e3(e4) {
              var r3 = t3.call(this, e4, s.default, h.default, 4, 5) || this, i3 = e4.createBuffer();
              if (null === i3) throw new Error("EdgeProgram: error while creating indicesBuffer");
              r3.indicesBuffer = i3, r3.positionLocation = e4.getAttribLocation(r3.program, "a_position"), r3.colorLocation = e4.getAttribLocation(r3.program, "a_color"), r3.normalLocation = e4.getAttribLocation(r3.program, "a_normal");
              var n2 = e4.getUniformLocation(r3.program, "u_matrix");
              if (null === n2) throw new Error("EdgeProgram: error while getting matrixLocation");
              r3.matrixLocation = n2;
              var o2 = e4.getUniformLocation(r3.program, "u_correctionRatio");
              if (null === o2) throw new Error("EdgeProgram: error while getting correctionRatioLocation");
              r3.correctionRatioLocation = o2;
              var l2 = e4.getUniformLocation(r3.program, "u_sqrtZoomRatio");
              if (null === l2) throw new Error("EdgeProgram: error while getting sqrtZoomRatioLocation");
              return r3.sqrtZoomRatioLocation = l2, r3.canUse32BitsIndices = (0, a.canUse32BitsIndices)(e4), r3.IndicesArray = r3.canUse32BitsIndices ? Uint32Array : Uint16Array, r3.indicesArray = new r3.IndicesArray(), r3.indicesType = r3.canUse32BitsIndices ? e4.UNSIGNED_INT : e4.UNSIGNED_SHORT, r3.bind(), r3;
            }
            return n(e3, t3), e3.prototype.bind = function() {
              var t4 = this.gl;
              t4.bindBuffer(t4.ELEMENT_ARRAY_BUFFER, this.indicesBuffer), t4.enableVertexAttribArray(this.positionLocation), t4.enableVertexAttribArray(this.normalLocation), t4.enableVertexAttribArray(this.colorLocation), t4.vertexAttribPointer(this.positionLocation, 2, t4.FLOAT, false, 5 * Float32Array.BYTES_PER_ELEMENT, 0), t4.vertexAttribPointer(this.normalLocation, 2, t4.FLOAT, false, 5 * Float32Array.BYTES_PER_ELEMENT, 8), t4.vertexAttribPointer(this.colorLocation, 4, t4.UNSIGNED_BYTE, true, 5 * Float32Array.BYTES_PER_ELEMENT, 16);
            }, e3.prototype.computeIndices = function() {
              for (var t4 = this.array.length / 5, e4 = t4 + t4 / 2, r3 = new this.IndicesArray(e4), i3 = 0, n2 = 0; i3 < t4; i3 += 4) r3[n2++] = i3, r3[n2++] = i3 + 1, r3[n2++] = i3 + 2, r3[n2++] = i3 + 2, r3[n2++] = i3 + 1, r3[n2++] = i3 + 3;
              this.indicesArray = r3;
            }, e3.prototype.bufferData = function() {
              t3.prototype.bufferData.call(this);
              var e4 = this.gl;
              e4.bufferData(e4.ELEMENT_ARRAY_BUFFER, this.indicesArray, e4.STATIC_DRAW);
            }, e3.prototype.process = function(t4, e4, r3, i3, n2) {
              if (i3) for (var o2 = 20 * n2, s2 = o2 + 20; o2 < s2; o2++) this.array[o2] = 0;
              else {
                var h2 = r3.size || 1, l2 = t4.x, c = t4.y, u = e4.x, d = e4.y, f = (0, a.floatColor)(r3.color), p = u - l2, g = d - c, v = p * p + g * g, m = 0, y = 0;
                v && (m = -g * (v = 1 / Math.sqrt(v)) * h2, y = p * v * h2);
                var b = 20 * n2, _ = this.array;
                _[b++] = l2, _[b++] = c, _[b++] = m, _[b++] = y, _[b++] = f, _[b++] = l2, _[b++] = c, _[b++] = -m, _[b++] = -y, _[b++] = f, _[b++] = u, _[b++] = d, _[b++] = m, _[b++] = y, _[b++] = f, _[b++] = u, _[b++] = d, _[b++] = -m, _[b++] = -y, _[b] = f;
              }
            }, e3.prototype.render = function(t4) {
              if (!this.hasNothingToRender()) {
                var e4 = this.gl, r3 = this.program;
                e4.useProgram(r3), e4.uniformMatrix3fv(this.matrixLocation, false, t4.matrix), e4.uniform1f(this.sqrtZoomRatioLocation, Math.sqrt(t4.ratio)), e4.uniform1f(this.correctionRatioLocation, t4.correctionRatio), e4.drawElements(e4.TRIANGLES, this.indicesArray.length, this.indicesType, 0);
              }
            }, e3;
          }(r2(195).AbstractEdgeProgram);
          e2.default = l;
        }, 582: function(t2, e2, r2) {
          "use strict";
          var i2, n = this && this.__extends || (i2 = function(t3, e3) {
            return i2 = Object.setPrototypeOf || { __proto__: [] } instanceof Array && function(t4, e4) {
              t4.__proto__ = e4;
            } || function(t4, e4) {
              for (var r3 in e4) Object.prototype.hasOwnProperty.call(e4, r3) && (t4[r3] = e4[r3]);
            }, i2(t3, e3);
          }, function(t3, e3) {
            if ("function" != typeof e3 && null !== e3) throw new TypeError("Class extends value " + String(e3) + " is not a constructor or null");
            function r3() {
              this.constructor = t3;
            }
            i2(t3, e3), t3.prototype = null === e3 ? Object.create(e3) : (r3.prototype = e3.prototype, new r3());
          }), o = this && this.__importDefault || function(t3) {
            return t3 && t3.__esModule ? t3 : { default: t3 };
          };
          Object.defineProperty(e2, "__esModule", { value: true });
          var a = r2(928), s = o(r2(106)), h = o(r2(262)), l = function(t3) {
            function e3(e4) {
              var r3 = t3.call(this, e4, s.default, h.default, 1, 4) || this;
              return r3.bind(), r3;
            }
            return n(e3, t3), e3.prototype.process = function(t4, e4, r3) {
              var i3 = this.array, n2 = 1 * r3 * 4;
              if (e4) return i3[n2++] = 0, i3[n2++] = 0, i3[n2++] = 0, void (i3[n2++] = 0);
              var o2 = (0, a.floatColor)(t4.color);
              i3[n2++] = t4.x, i3[n2++] = t4.y, i3[n2++] = t4.size, i3[n2] = o2;
            }, e3.prototype.render = function(t4) {
              if (!this.hasNothingToRender()) {
                var e4 = this.gl, r3 = this.program;
                e4.useProgram(r3), e4.uniform1f(this.ratioLocation, 1 / Math.sqrt(t4.ratio)), e4.uniform1f(this.scaleLocation, t4.scalingRatio), e4.uniformMatrix3fv(this.matrixLocation, false, t4.matrix), e4.drawArrays(e4.POINTS, 0, this.array.length / 4);
              }
            }, e3;
          }(r2(909).AbstractNodeProgram);
          e2.default = l;
        }, 706: (t2, e2) => {
          "use strict";
          function r2(t3, e3, r3) {
            var i2 = "VERTEX" === t3 ? e3.VERTEX_SHADER : e3.FRAGMENT_SHADER, n = e3.createShader(i2);
            if (null === n) throw new Error("loadShader: error while creating the shader");
            if (e3.shaderSource(n, r3), e3.compileShader(n), !e3.getShaderParameter(n, e3.COMPILE_STATUS)) {
              var o = e3.getShaderInfoLog(n);
              throw e3.deleteShader(n), new Error("loadShader: error while compiling the shader:\n".concat(o, "\n").concat(r3));
            }
            return n;
          }
          Object.defineProperty(e2, "__esModule", { value: true }), e2.loadProgram = e2.loadFragmentShader = e2.loadVertexShader = void 0, e2.loadVertexShader = function(t3, e3) {
            return r2("VERTEX", t3, e3);
          }, e2.loadFragmentShader = function(t3, e3) {
            return r2("FRAGMENT", t3, e3);
          }, e2.loadProgram = function(t3, e3) {
            var r3, i2, n = t3.createProgram();
            if (null === n) throw new Error("loadProgram: error while creating the program.");
            for (r3 = 0, i2 = e3.length; r3 < i2; r3++) t3.attachShader(n, e3[r3]);
            if (t3.linkProgram(n), !t3.getProgramParameter(n, t3.LINK_STATUS)) throw t3.deleteProgram(n), new Error("loadProgram: error while linking the program.");
            return n;
          };
        }, 310: function(t2, e2, r2) {
          "use strict";
          var i2 = this && this.__importDefault || function(t3) {
            return t3 && t3.__esModule ? t3 : { default: t3 };
          };
          Object.defineProperty(e2, "__esModule", { value: true }), e2.resolveSettings = e2.validateSettings = e2.DEFAULT_EDGE_PROGRAM_CLASSES = e2.DEFAULT_NODE_PROGRAM_CLASSES = e2.DEFAULT_SETTINGS = void 0;
          var n = r2(928), o = i2(r2(622)), a = i2(r2(61)), s = i2(r2(942)), h = i2(r2(582)), l = i2(r2(753)), c = i2(r2(569));
          e2.DEFAULT_SETTINGS = { hideEdgesOnMove: false, hideLabelsOnMove: false, renderLabels: true, renderEdgeLabels: false, enableEdgeClickEvents: false, enableEdgeWheelEvents: false, enableEdgeHoverEvents: false, defaultNodeColor: "#999", defaultNodeType: "circle", defaultEdgeColor: "#ccc", defaultEdgeType: "line", labelFont: "Arial", labelSize: 14, labelWeight: "normal", labelColor: { color: "#000" }, edgeLabelFont: "Arial", edgeLabelSize: 14, edgeLabelWeight: "normal", edgeLabelColor: { attribute: "color" }, stagePadding: 30, labelDensity: 1, labelGridCellSize: 100, labelRenderedSizeThreshold: 6, nodeReducer: null, edgeReducer: null, zIndex: false, minCameraRatio: null, maxCameraRatio: null, labelRenderer: o.default, hoverRenderer: a.default, edgeLabelRenderer: s.default, allowInvalidContainer: false, nodeProgramClasses: {}, nodeHoverProgramClasses: {}, edgeProgramClasses: {} }, e2.DEFAULT_NODE_PROGRAM_CLASSES = { circle: h.default }, e2.DEFAULT_EDGE_PROGRAM_CLASSES = { arrow: c.default, line: l.default }, e2.validateSettings = function(t3) {
            if ("number" != typeof t3.labelDensity || t3.labelDensity < 0) throw new Error("Settings: invalid `labelDensity`. Expecting a positive number.");
            var e3 = t3.minCameraRatio, r3 = t3.maxCameraRatio;
            if ("number" == typeof e3 && "number" == typeof r3 && r3 < e3) throw new Error("Settings: invalid camera ratio boundaries. Expecting `maxCameraRatio` to be greater than `minCameraRatio`.");
          }, e2.resolveSettings = function(t3) {
            var r3 = (0, n.assign)({}, e2.DEFAULT_SETTINGS, t3);
            return r3.nodeProgramClasses = (0, n.assign)({}, e2.DEFAULT_NODE_PROGRAM_CLASSES, r3.nodeProgramClasses), r3.edgeProgramClasses = (0, n.assign)({}, e2.DEFAULT_EDGE_PROGRAM_CLASSES, r3.edgeProgramClasses), r3;
          };
        }, 159: function(t2, e2, r2) {
          "use strict";
          var i2, n = this && this.__extends || (i2 = function(t3, e3) {
            return i2 = Object.setPrototypeOf || { __proto__: [] } instanceof Array && function(t4, e4) {
              t4.__proto__ = e4;
            } || function(t4, e4) {
              for (var r3 in e4) Object.prototype.hasOwnProperty.call(e4, r3) && (t4[r3] = e4[r3]);
            }, i2(t3, e3);
          }, function(t3, e3) {
            if ("function" != typeof e3 && null !== e3) throw new TypeError("Class extends value " + String(e3) + " is not a constructor or null");
            function r3() {
              this.constructor = t3;
            }
            i2(t3, e3), t3.prototype = null === e3 ? Object.create(e3) : (r3.prototype = e3.prototype, new r3());
          }), o = this && this.__assign || function() {
            return o = Object.assign || function(t3) {
              for (var e3, r3 = 1, i3 = arguments.length; r3 < i3; r3++) for (var n2 in e3 = arguments[r3]) Object.prototype.hasOwnProperty.call(e3, n2) && (t3[n2] = e3[n2]);
              return t3;
            }, o.apply(this, arguments);
          }, a = this && this.__values || function(t3) {
            var e3 = "function" == typeof Symbol && Symbol.iterator, r3 = e3 && t3[e3], i3 = 0;
            if (r3) return r3.call(t3);
            if (t3 && "number" == typeof t3.length) return { next: function() {
              return t3 && i3 >= t3.length && (t3 = void 0), { value: t3 && t3[i3++], done: !t3 };
            } };
            throw new TypeError(e3 ? "Object is not iterable." : "Symbol.iterator is not defined.");
          }, s = this && this.__importDefault || function(t3) {
            return t3 && t3.__esModule ? t3 : { default: t3 };
          };
          Object.defineProperty(e2, "__esModule", { value: true });
          var h = s(r2(796)), l = s(r2(764)), c = s(r2(269)), u = s(r2(134)), d = r2(699), f = r2(928), p = r2(730), g = r2(310), v = s(r2(508)), m = r2(700), y = r2(628);
          function b(t3, e3, r3) {
            if (!r3.hasOwnProperty("x") || !r3.hasOwnProperty("y")) throw new Error('Sigma: could not find a valid position (x, y) for node "'.concat(e3, '". All your nodes must have a number "x" and "y". Maybe your forgot to apply a layout or your "nodeReducer" is not returning the correct data?'));
            return r3.color || (r3.color = t3.defaultNodeColor), r3.label || "" === r3.label || (r3.label = null), void 0 !== r3.label && null !== r3.label ? r3.label = "" + r3.label : r3.label = null, r3.size || (r3.size = 2), r3.hasOwnProperty("hidden") || (r3.hidden = false), r3.hasOwnProperty("highlighted") || (r3.highlighted = false), r3.hasOwnProperty("forceLabel") || (r3.forceLabel = false), r3.type && "" !== r3.type || (r3.type = t3.defaultNodeType), r3.zIndex || (r3.zIndex = 0), r3;
          }
          function _(t3, e3, r3) {
            return r3.color || (r3.color = t3.defaultEdgeColor), r3.label || (r3.label = ""), r3.size || (r3.size = 0.5), r3.hasOwnProperty("hidden") || (r3.hidden = false), r3.hasOwnProperty("forceLabel") || (r3.forceLabel = false), r3.type && "" !== r3.type || (r3.type = t3.defaultEdgeType), r3.zIndex || (r3.zIndex = 0), r3;
          }
          var x = function(t3) {
            function e3(e4, r3, i3) {
              void 0 === i3 && (i3 = {});
              var n2 = t3.call(this) || this;
              if (n2.elements = {}, n2.canvasContexts = {}, n2.webGLContexts = {}, n2.activeListeners = {}, n2.quadtree = new u.default(), n2.labelGrid = new p.LabelGrid(), n2.nodeDataCache = {}, n2.edgeDataCache = {}, n2.nodesWithForcedLabels = [], n2.edgesWithForcedLabels = [], n2.nodeExtent = { x: [0, 1], y: [0, 1] }, n2.matrix = (0, m.identity)(), n2.invMatrix = (0, m.identity)(), n2.correctionRatio = 1, n2.customBBox = null, n2.normalizationFunction = (0, f.createNormalizationFunction)({ x: [0, 1], y: [0, 1] }), n2.cameraSizeRatio = 1, n2.width = 0, n2.height = 0, n2.pixelRatio = (0, f.getPixelRatio)(), n2.displayedLabels = /* @__PURE__ */ new Set(), n2.highlightedNodes = /* @__PURE__ */ new Set(), n2.hoveredNode = null, n2.hoveredEdge = null, n2.renderFrame = null, n2.renderHighlightedNodesFrame = null, n2.needToProcess = false, n2.needToSoftProcess = false, n2.checkEdgesEventsFrame = null, n2.nodePrograms = {}, n2.nodeHoverPrograms = {}, n2.edgePrograms = {}, n2.settings = (0, g.resolveSettings)(i3), (0, g.validateSettings)(n2.settings), (0, f.validateGraph)(e4), !(r3 instanceof HTMLElement)) throw new Error("Sigma: container should be an html element.");
              for (var o2 in n2.graph = e4, n2.container = r3, n2.createWebGLContext("edges", { preserveDrawingBuffer: true }), n2.createCanvasContext("edgeLabels"), n2.createWebGLContext("nodes"), n2.createCanvasContext("labels"), n2.createCanvasContext("hovers"), n2.createWebGLContext("hoverNodes"), n2.createCanvasContext("mouse"), n2.webGLContexts) {
                var a2 = n2.webGLContexts[o2];
                a2.blendFunc(a2.ONE, a2.ONE_MINUS_SRC_ALPHA), a2.enable(a2.BLEND);
              }
              for (var s2 in n2.settings.nodeProgramClasses) {
                var h2 = n2.settings.nodeProgramClasses[s2];
                n2.nodePrograms[s2] = new h2(n2.webGLContexts.nodes, n2);
                var d2 = h2;
                s2 in n2.settings.nodeHoverProgramClasses && (d2 = n2.settings.nodeHoverProgramClasses[s2]), n2.nodeHoverPrograms[s2] = new d2(n2.webGLContexts.hoverNodes, n2);
              }
              for (var s2 in n2.settings.edgeProgramClasses) {
                var y2 = n2.settings.edgeProgramClasses[s2];
                n2.edgePrograms[s2] = new y2(n2.webGLContexts.edges, n2);
              }
              return n2.resize(), n2.camera = new l.default(), n2.bindCameraHandlers(), n2.mouseCaptor = new c.default(n2.elements.mouse, n2), n2.touchCaptor = new v.default(n2.elements.mouse, n2), n2.bindEventHandlers(), n2.bindGraphHandlers(), n2.handleSettingsUpdate(), n2.process(), n2.render(), n2;
            }
            return n(e3, t3), e3.prototype.createCanvas = function(t4) {
              var e4 = (0, f.createElement)("canvas", { position: "absolute" }, { class: "sigma-".concat(t4) });
              return this.elements[t4] = e4, this.container.appendChild(e4), e4;
            }, e3.prototype.createCanvasContext = function(t4) {
              var e4 = this.createCanvas(t4);
              return this.canvasContexts[t4] = e4.getContext("2d", { preserveDrawingBuffer: false, antialias: false }), this;
            }, e3.prototype.createWebGLContext = function(t4, e4) {
              var r3, i3 = this.createCanvas(t4), n2 = o({ preserveDrawingBuffer: false, antialias: false }, e4 || {});
              return (r3 = i3.getContext("webgl2", n2)) || (r3 = i3.getContext("webgl", n2)), r3 || (r3 = i3.getContext("experimental-webgl", n2)), this.webGLContexts[t4] = r3, this;
            }, e3.prototype.bindCameraHandlers = function() {
              var t4 = this;
              return this.activeListeners.camera = function() {
                t4._scheduleRefresh();
              }, this.camera.on("updated", this.activeListeners.camera), this;
            }, e3.prototype.mouseIsOnNode = function(t4, e4, r3) {
              var i3 = t4.x, n2 = t4.y, o2 = e4.x, a2 = e4.y;
              return i3 > o2 - r3 && i3 < o2 + r3 && n2 > a2 - r3 && n2 < a2 + r3 && Math.sqrt(Math.pow(i3 - o2, 2) + Math.pow(n2 - a2, 2)) < r3;
            }, e3.prototype.getQuadNodes = function(t4) {
              var e4 = this.viewportToFramedGraph(t4);
              return this.quadtree.point(e4.x, 1 - e4.y);
            }, e3.prototype.getNodeAtPosition = function(t4) {
              for (var e4 = t4.x, r3 = t4.y, i3 = this.getQuadNodes(t4), n2 = 1 / 0, o2 = null, a2 = 0, s2 = i3.length; a2 < s2; a2++) {
                var h2 = i3[a2], l2 = this.nodeDataCache[h2], c2 = this.framedGraphToViewport(l2), u2 = this.scaleSize(l2.size);
                if (!l2.hidden && this.mouseIsOnNode(t4, c2, u2)) {
                  var d2 = Math.sqrt(Math.pow(e4 - c2.x, 2) + Math.pow(r3 - c2.y, 2));
                  d2 < n2 && (n2 = d2, o2 = h2);
                }
              }
              return o2;
            }, e3.prototype.bindEventHandlers = function() {
              var t4 = this;
              this.activeListeners.handleResize = function() {
                t4.needToSoftProcess = true, t4._scheduleRefresh();
              }, window.addEventListener("resize", this.activeListeners.handleResize), this.activeListeners.handleMove = function(e5) {
                var r3 = { event: e5, preventSigmaDefault: function() {
                  e5.preventSigmaDefault();
                } }, i3 = t4.getNodeAtPosition(e5);
                if (i3 && t4.hoveredNode !== i3 && !t4.nodeDataCache[i3].hidden) return t4.hoveredNode && t4.emit("leaveNode", o(o({}, r3), { node: t4.hoveredNode })), t4.hoveredNode = i3, t4.emit("enterNode", o(o({}, r3), { node: i3 })), void t4.scheduleHighlightedNodesRender();
                if (t4.hoveredNode) {
                  var n2 = t4.nodeDataCache[t4.hoveredNode], a2 = t4.framedGraphToViewport(n2), s2 = t4.scaleSize(n2.size);
                  if (!t4.mouseIsOnNode(e5, a2, s2)) {
                    var h2 = t4.hoveredNode;
                    return t4.hoveredNode = null, t4.emit("leaveNode", o(o({}, r3), { node: h2 })), void t4.scheduleHighlightedNodesRender();
                  }
                }
                true === t4.settings.enableEdgeHoverEvents ? t4.checkEdgeHoverEvents(r3) : "debounce" === t4.settings.enableEdgeHoverEvents && (t4.checkEdgesEventsFrame || (t4.checkEdgesEventsFrame = (0, f.requestFrame)(function() {
                  t4.checkEdgeHoverEvents(r3), t4.checkEdgesEventsFrame = null;
                })));
              };
              var e4 = function(e5) {
                return function(r3) {
                  var i3 = { event: r3, preventSigmaDefault: function() {
                    r3.preventSigmaDefault();
                  } }, n2 = r3.original.isFakeSigmaMouseEvent ? t4.getNodeAtPosition(r3) : t4.hoveredNode;
                  if (n2) return t4.emit("".concat(e5, "Node"), o(o({}, i3), { node: n2 }));
                  if ("wheel" === e5 ? t4.settings.enableEdgeWheelEvents : t4.settings.enableEdgeClickEvents) {
                    var a2 = t4.getEdgeAtPoint(r3.x, r3.y);
                    if (a2) return t4.emit("".concat(e5, "Edge"), o(o({}, i3), { edge: a2 }));
                  }
                  return t4.emit("".concat(e5, "Stage"), i3);
                };
              };
              return this.activeListeners.handleClick = e4("click"), this.activeListeners.handleRightClick = e4("rightClick"), this.activeListeners.handleDoubleClick = e4("doubleClick"), this.activeListeners.handleWheel = e4("wheel"), this.activeListeners.handleDown = e4("down"), this.mouseCaptor.on("mousemove", this.activeListeners.handleMove), this.mouseCaptor.on("click", this.activeListeners.handleClick), this.mouseCaptor.on("rightClick", this.activeListeners.handleRightClick), this.mouseCaptor.on("doubleClick", this.activeListeners.handleDoubleClick), this.mouseCaptor.on("wheel", this.activeListeners.handleWheel), this.mouseCaptor.on("mousedown", this.activeListeners.handleDown), this;
            }, e3.prototype.bindGraphHandlers = function() {
              var t4 = this, e4 = this.graph;
              return this.activeListeners.graphUpdate = function() {
                t4.needToProcess = true, t4._scheduleRefresh();
              }, this.activeListeners.softGraphUpdate = function() {
                t4.needToSoftProcess = true, t4._scheduleRefresh();
              }, this.activeListeners.dropNodeGraphUpdate = function(e5) {
                delete t4.nodeDataCache[e5.key], t4.hoveredNode === e5.key && (t4.hoveredNode = null), t4.activeListeners.graphUpdate();
              }, this.activeListeners.dropEdgeGraphUpdate = function(e5) {
                delete t4.edgeDataCache[e5.key], t4.hoveredEdge === e5.key && (t4.hoveredEdge = null), t4.activeListeners.graphUpdate();
              }, this.activeListeners.clearEdgesGraphUpdate = function() {
                t4.edgeDataCache = {}, t4.hoveredEdge = null, t4.activeListeners.graphUpdate();
              }, this.activeListeners.clearGraphUpdate = function() {
                t4.nodeDataCache = {}, t4.hoveredNode = null, t4.activeListeners.clearEdgesGraphUpdate();
              }, e4.on("nodeAdded", this.activeListeners.graphUpdate), e4.on("nodeDropped", this.activeListeners.dropNodeGraphUpdate), e4.on("nodeAttributesUpdated", this.activeListeners.softGraphUpdate), e4.on("eachNodeAttributesUpdated", this.activeListeners.graphUpdate), e4.on("edgeAdded", this.activeListeners.graphUpdate), e4.on("edgeDropped", this.activeListeners.dropEdgeGraphUpdate), e4.on("edgeAttributesUpdated", this.activeListeners.softGraphUpdate), e4.on("eachEdgeAttributesUpdated", this.activeListeners.graphUpdate), e4.on("edgesCleared", this.activeListeners.clearEdgesGraphUpdate), e4.on("cleared", this.activeListeners.clearGraphUpdate), this;
            }, e3.prototype.unbindGraphHandlers = function() {
              var t4 = this.graph;
              t4.removeListener("nodeAdded", this.activeListeners.graphUpdate), t4.removeListener("nodeDropped", this.activeListeners.dropNodeGraphUpdate), t4.removeListener("nodeAttributesUpdated", this.activeListeners.softGraphUpdate), t4.removeListener("eachNodeAttributesUpdated", this.activeListeners.graphUpdate), t4.removeListener("edgeAdded", this.activeListeners.graphUpdate), t4.removeListener("edgeDropped", this.activeListeners.dropEdgeGraphUpdate), t4.removeListener("edgeAttributesUpdated", this.activeListeners.softGraphUpdate), t4.removeListener("eachEdgeAttributesUpdated", this.activeListeners.graphUpdate), t4.removeListener("edgesCleared", this.activeListeners.clearEdgesGraphUpdate), t4.removeListener("cleared", this.activeListeners.clearGraphUpdate);
            }, e3.prototype.checkEdgeHoverEvents = function(t4) {
              var e4 = this.hoveredNode ? null : this.getEdgeAtPoint(t4.event.x, t4.event.y);
              return e4 !== this.hoveredEdge && (this.hoveredEdge && this.emit("leaveEdge", o(o({}, t4), { edge: this.hoveredEdge })), e4 && this.emit("enterEdge", o(o({}, t4), { edge: e4 })), this.hoveredEdge = e4), this;
            }, e3.prototype.getEdgeAtPoint = function(t4, e4) {
              var r3, i3, n2 = this, o2 = this.edgeDataCache, s2 = this.nodeDataCache;
              if (!(0, y.isPixelColored)(this.webGLContexts.edges, t4 * this.pixelRatio, e4 * this.pixelRatio)) return null;
              var h2 = this.viewportToGraph({ x: t4, y: e4 }), l2 = h2.x, c2 = h2.y, u2 = 0;
              if (this.graph.someEdge(function(t5, e5, r4, i4, a2, h3) {
                var l3 = a2.x, c3 = a2.y, d3 = h3.x, f3 = h3.y;
                if (o2[t5].hidden || s2[r4].hidden || s2[i4].hidden) return false;
                if (l3 !== d3 || c3 !== f3) {
                  var p3 = Math.sqrt(Math.pow(d3 - l3, 2) + Math.pow(f3 - c3, 2)), g3 = n2.graphToViewport({ x: l3, y: c3 }), v3 = g3.x, m3 = g3.y, y2 = n2.graphToViewport({ x: d3, y: f3 }), b3 = y2.x, _2 = y2.y, x2 = Math.sqrt(Math.pow(b3 - v3, 2) + Math.pow(_2 - m3, 2));
                  return u2 = p3 / x2, true;
                }
              }), !u2) return null;
              var d2 = this.graph.filterEdges(function(t5, e5, r4, i4, a2, h3) {
                return !(o2[t5].hidden || s2[r4].hidden || s2[i4].hidden) && (!!(0, y.doEdgeCollideWithPoint)(l2, c2, a2.x, a2.y, h3.x, h3.y, o2[t5].size * u2 / n2.cameraSizeRatio) || void 0);
              });
              if (0 === d2.length) return null;
              var f2 = d2[d2.length - 1], p2 = -1 / 0;
              try {
                for (var g2 = a(d2), v2 = g2.next(); !v2.done; v2 = g2.next()) {
                  var m2 = v2.value, b2 = this.graph.getEdgeAttribute(m2, "zIndex");
                  b2 >= p2 && (f2 = m2, p2 = b2);
                }
              } catch (t5) {
                r3 = { error: t5 };
              } finally {
                try {
                  v2 && !v2.done && (i3 = g2.return) && i3.call(g2);
                } finally {
                  if (r3) throw r3.error;
                }
              }
              return f2;
            }, e3.prototype.process = function(t4) {
              var e4 = this;
              void 0 === t4 && (t4 = false);
              var r3 = this.graph, i3 = this.settings, n2 = this.getDimensions(), o2 = [1 / 0, -1 / 0], a2 = [1 / 0, -1 / 0];
              this.quadtree.clear(), this.labelGrid.resizeAndClear(n2, i3.labelGridCellSize), this.highlightedNodes = /* @__PURE__ */ new Set(), this.nodeExtent = (0, f.graphExtent)(r3), this.nodesWithForcedLabels = [], this.edgesWithForcedLabels = [];
              var s2 = new l.default(), h2 = (0, f.matrixFromCamera)(s2.getState(), this.getDimensions(), this.getGraphDimensions(), this.getSetting("stagePadding") || 0);
              this.normalizationFunction = (0, f.createNormalizationFunction)(this.customBBox || this.nodeExtent);
              for (var c2 = {}, u2 = r3.nodes(), d2 = 0, p2 = u2.length; d2 < p2; d2++) {
                var g2 = u2[d2], v2 = Object.assign({}, r3.getNodeAttributes(g2));
                i3.nodeReducer && (v2 = i3.nodeReducer(g2, v2)), c2[(y2 = b(this.settings, g2, v2)).type] = (c2[y2.type] || 0) + 1, this.nodeDataCache[g2] = y2, this.normalizationFunction.applyTo(y2), y2.forceLabel && this.nodesWithForcedLabels.push(g2), this.settings.zIndex && (y2.zIndex < o2[0] && (o2[0] = y2.zIndex), y2.zIndex > o2[1] && (o2[1] = y2.zIndex));
              }
              for (var m2 in this.nodePrograms) {
                if (!this.nodePrograms.hasOwnProperty(m2)) throw new Error('Sigma: could not find a suitable program for node type "'.concat(m2, '"!'));
                t4 || this.nodePrograms[m2].allocate(c2[m2] || 0), c2[m2] = 0;
              }
              for (this.settings.zIndex && o2[0] !== o2[1] && (u2 = (0, f.zIndexOrdering)(o2, function(t5) {
                return e4.nodeDataCache[t5].zIndex;
              }, u2)), d2 = 0, p2 = u2.length; d2 < p2; d2++) {
                g2 = u2[d2];
                var y2 = this.nodeDataCache[g2];
                this.quadtree.add(g2, y2.x, 1 - y2.y, y2.size / this.width), "string" != typeof y2.label || y2.hidden || this.labelGrid.add(g2, y2.size, this.framedGraphToViewport(y2, { matrix: h2 }));
                var x2 = this.nodePrograms[y2.type];
                if (!x2) throw new Error('Sigma: could not find a suitable program for node type "'.concat(y2.type, '"!'));
                x2.process(y2, y2.hidden, c2[y2.type]++), y2.highlighted && !y2.hidden && this.highlightedNodes.add(g2);
              }
              this.labelGrid.organize();
              var w = {}, E = r3.edges();
              for (d2 = 0, p2 = E.length; d2 < p2; d2++) {
                var L = E[d2];
                v2 = Object.assign({}, r3.getEdgeAttributes(L)), i3.edgeReducer && (v2 = i3.edgeReducer(L, v2)), w[(y2 = _(this.settings, 0, v2)).type] = (w[y2.type] || 0) + 1, this.edgeDataCache[L] = y2, y2.forceLabel && !y2.hidden && this.edgesWithForcedLabels.push(L), this.settings.zIndex && (y2.zIndex < a2[0] && (a2[0] = y2.zIndex), y2.zIndex > a2[1] && (a2[1] = y2.zIndex));
              }
              for (var m2 in this.edgePrograms) {
                if (!this.edgePrograms.hasOwnProperty(m2)) throw new Error('Sigma: could not find a suitable program for edge type "'.concat(m2, '"!'));
                t4 || this.edgePrograms[m2].allocate(w[m2] || 0), w[m2] = 0;
              }
              for (this.settings.zIndex && a2[0] !== a2[1] && (E = (0, f.zIndexOrdering)(a2, function(t5) {
                return e4.edgeDataCache[t5].zIndex;
              }, E)), d2 = 0, p2 = E.length; d2 < p2; d2++) {
                L = E[d2], y2 = this.edgeDataCache[L];
                var F = r3.extremities(L), C = this.nodeDataCache[F[0]], A = this.nodeDataCache[F[1]], T = y2.hidden || C.hidden || A.hidden;
                this.edgePrograms[y2.type].process(C, A, y2, T, w[y2.type]++);
              }
              for (var m2 in this.edgePrograms) {
                var P = this.edgePrograms[m2];
                t4 || "function" != typeof P.computeIndices || P.computeIndices();
              }
              return this;
            }, e3.prototype.handleSettingsUpdate = function() {
              return this.camera.minRatio = this.settings.minCameraRatio, this.camera.maxRatio = this.settings.maxCameraRatio, this.camera.setState(this.camera.validateState(this.camera.getState())), this;
            }, e3.prototype._refresh = function() {
              return this.needToProcess ? this.process() : this.needToSoftProcess && this.process(true), this.needToProcess = false, this.needToSoftProcess = false, this.render(), this;
            }, e3.prototype._scheduleRefresh = function() {
              var t4 = this;
              return this.renderFrame || (this.renderFrame = (0, f.requestFrame)(function() {
                t4._refresh(), t4.renderFrame = null;
              })), this;
            }, e3.prototype.renderLabels = function() {
              if (!this.settings.renderLabels) return this;
              var t4 = this.camera.getState(), e4 = this.labelGrid.getLabelsToDisplay(t4.ratio, this.settings.labelDensity);
              (0, h.default)(e4, this.nodesWithForcedLabels), this.displayedLabels = /* @__PURE__ */ new Set();
              for (var r3 = this.canvasContexts.labels, i3 = 0, n2 = e4.length; i3 < n2; i3++) {
                var a2 = e4[i3], s2 = this.nodeDataCache[a2];
                if (!this.displayedLabels.has(a2) && !s2.hidden) {
                  var l2 = this.framedGraphToViewport(s2), c2 = l2.x, u2 = l2.y, d2 = this.scaleSize(s2.size);
                  !s2.forceLabel && d2 < this.settings.labelRenderedSizeThreshold || c2 < -150 || c2 > this.width + 150 || u2 < -50 || u2 > this.height + 50 || (this.displayedLabels.add(a2), this.settings.labelRenderer(r3, o(o({ key: a2 }, s2), { size: d2, x: c2, y: u2 }), this.settings));
                }
              }
              return this;
            }, e3.prototype.renderEdgeLabels = function() {
              if (!this.settings.renderEdgeLabels) return this;
              var t4 = this.canvasContexts.edgeLabels;
              t4.clearRect(0, 0, this.width, this.height);
              for (var e4 = (0, p.edgeLabelsToDisplayFromNodes)({ graph: this.graph, hoveredNode: this.hoveredNode, displayedNodeLabels: this.displayedLabels, highlightedNodes: this.highlightedNodes }).concat(this.edgesWithForcedLabels), r3 = /* @__PURE__ */ new Set(), i3 = 0, n2 = e4.length; i3 < n2; i3++) {
                var a2 = e4[i3], s2 = this.graph.extremities(a2), h2 = this.nodeDataCache[s2[0]], l2 = this.nodeDataCache[s2[1]], c2 = this.edgeDataCache[a2];
                r3.has(a2) || c2.hidden || h2.hidden || l2.hidden || (this.settings.edgeLabelRenderer(t4, o(o({ key: a2 }, c2), { size: this.scaleSize(c2.size) }), o(o(o({ key: s2[0] }, h2), this.framedGraphToViewport(h2)), { size: this.scaleSize(h2.size) }), o(o(o({ key: s2[1] }, l2), this.framedGraphToViewport(l2)), { size: this.scaleSize(l2.size) }), this.settings), r3.add(a2));
              }
              return this;
            }, e3.prototype.renderHighlightedNodes = function() {
              var t4 = this, e4 = this.canvasContexts.hovers;
              e4.clearRect(0, 0, this.width, this.height);
              var r3 = [];
              this.hoveredNode && !this.nodeDataCache[this.hoveredNode].hidden && r3.push(this.hoveredNode), this.highlightedNodes.forEach(function(e5) {
                e5 !== t4.hoveredNode && r3.push(e5);
              }), r3.forEach(function(r4) {
                return function(r5) {
                  var i4 = t4.nodeDataCache[r5], n3 = t4.framedGraphToViewport(i4), a3 = n3.x, s2 = n3.y, h2 = t4.scaleSize(i4.size);
                  t4.settings.hoverRenderer(e4, o(o({ key: r5 }, i4), { size: h2, x: a3, y: s2 }), t4.settings);
                }(r4);
              });
              var i3 = {};
              for (var n2 in r3.forEach(function(e5) {
                var r4 = t4.nodeDataCache[e5].type;
                i3[r4] = (i3[r4] || 0) + 1;
              }), this.nodeHoverPrograms) this.nodeHoverPrograms[n2].allocate(i3[n2] || 0), i3[n2] = 0;
              for (var n2 in r3.forEach(function(e5) {
                var r4 = t4.nodeDataCache[e5];
                t4.nodeHoverPrograms[r4.type].process(r4, r4.hidden, i3[r4.type]++);
              }), this.webGLContexts.hoverNodes.clear(this.webGLContexts.hoverNodes.COLOR_BUFFER_BIT), this.nodeHoverPrograms) {
                var a2 = this.nodeHoverPrograms[n2];
                a2.bind(), a2.bufferData(), a2.render({ matrix: this.matrix, width: this.width, height: this.height, ratio: this.camera.ratio, correctionRatio: this.correctionRatio / this.camera.ratio, scalingRatio: this.pixelRatio });
              }
            }, e3.prototype.scheduleHighlightedNodesRender = function() {
              var t4 = this;
              this.renderHighlightedNodesFrame || this.renderFrame || (this.renderHighlightedNodesFrame = (0, f.requestFrame)(function() {
                t4.renderHighlightedNodesFrame = null, t4.renderHighlightedNodes(), t4.renderEdgeLabels();
              }));
            }, e3.prototype.render = function() {
              var t4 = this;
              this.emit("beforeRender");
              var e4 = function() {
                return t4.emit("afterRender"), t4;
              };
              if (this.renderFrame && ((0, f.cancelFrame)(this.renderFrame), this.renderFrame = null, this.needToProcess = false, this.needToSoftProcess = false), this.resize(), this.clear(), this.updateCachedValues(), !this.graph.order) return e4();
              var r3 = this.mouseCaptor, i3 = this.camera.isAnimated() || r3.isMoving || r3.draggedEvents || r3.currentWheelDirection, n2 = this.camera.getState(), o2 = this.getDimensions(), a2 = this.getGraphDimensions(), s2 = this.getSetting("stagePadding") || 0;
              for (var h2 in this.matrix = (0, f.matrixFromCamera)(n2, o2, a2, s2), this.invMatrix = (0, f.matrixFromCamera)(n2, o2, a2, s2, true), this.correctionRatio = (0, f.getMatrixImpact)(this.matrix, n2, o2), this.nodePrograms) (l2 = this.nodePrograms[h2]).bind(), l2.bufferData(), l2.render({ matrix: this.matrix, width: this.width, height: this.height, ratio: n2.ratio, correctionRatio: this.correctionRatio / n2.ratio, scalingRatio: this.pixelRatio });
              if (!this.settings.hideEdgesOnMove || !i3) for (var h2 in this.edgePrograms) {
                var l2;
                (l2 = this.edgePrograms[h2]).bind(), l2.bufferData(), l2.render({ matrix: this.matrix, width: this.width, height: this.height, ratio: n2.ratio, correctionRatio: this.correctionRatio / n2.ratio, scalingRatio: this.pixelRatio });
              }
              return this.settings.hideLabelsOnMove && i3 || (this.renderLabels(), this.renderEdgeLabels(), this.renderHighlightedNodes()), e4();
            }, e3.prototype.updateCachedValues = function() {
              var t4 = this.camera.getState().ratio;
              this.cameraSizeRatio = Math.sqrt(t4);
            }, e3.prototype.getCamera = function() {
              return this.camera;
            }, e3.prototype.getContainer = function() {
              return this.container;
            }, e3.prototype.getGraph = function() {
              return this.graph;
            }, e3.prototype.setGraph = function(t4) {
              t4 !== this.graph && (this.unbindGraphHandlers(), this.nodeDataCache = {}, this.edgeDataCache = {}, this.displayedLabels.clear(), this.highlightedNodes.clear(), this.hoveredNode = null, this.hoveredEdge = null, this.nodesWithForcedLabels.length = 0, this.edgesWithForcedLabels.length = 0, null !== this.checkEdgesEventsFrame && ((0, f.cancelFrame)(this.checkEdgesEventsFrame), this.checkEdgesEventsFrame = null), this.graph = t4, this.bindGraphHandlers(), this.process(), this.render());
            }, e3.prototype.getMouseCaptor = function() {
              return this.mouseCaptor;
            }, e3.prototype.getTouchCaptor = function() {
              return this.touchCaptor;
            }, e3.prototype.getDimensions = function() {
              return { width: this.width, height: this.height };
            }, e3.prototype.getGraphDimensions = function() {
              var t4 = this.customBBox || this.nodeExtent;
              return { width: t4.x[1] - t4.x[0] || 1, height: t4.y[1] - t4.y[0] || 1 };
            }, e3.prototype.getNodeDisplayData = function(t4) {
              var e4 = this.nodeDataCache[t4];
              return e4 ? Object.assign({}, e4) : void 0;
            }, e3.prototype.getEdgeDisplayData = function(t4) {
              var e4 = this.edgeDataCache[t4];
              return e4 ? Object.assign({}, e4) : void 0;
            }, e3.prototype.getSettings = function() {
              return o({}, this.settings);
            }, e3.prototype.getSetting = function(t4) {
              return this.settings[t4];
            }, e3.prototype.setSetting = function(t4, e4) {
              return this.settings[t4] = e4, (0, g.validateSettings)(this.settings), this.handleSettingsUpdate(), this.needToProcess = true, this._scheduleRefresh(), this;
            }, e3.prototype.updateSetting = function(t4, e4) {
              return this.settings[t4] = e4(this.settings[t4]), (0, g.validateSettings)(this.settings), this.handleSettingsUpdate(), this.needToProcess = true, this._scheduleRefresh(), this;
            }, e3.prototype.resize = function() {
              var t4 = this.width, e4 = this.height;
              if (this.width = this.container.offsetWidth, this.height = this.container.offsetHeight, this.pixelRatio = (0, f.getPixelRatio)(), 0 === this.width) {
                if (!this.settings.allowInvalidContainer) throw new Error("Sigma: Container has no width. You can set the allowInvalidContainer setting to true to stop seeing this error.");
                this.width = 1;
              }
              if (0 === this.height) {
                if (!this.settings.allowInvalidContainer) throw new Error("Sigma: Container has no height. You can set the allowInvalidContainer setting to true to stop seeing this error.");
                this.height = 1;
              }
              if (t4 === this.width && e4 === this.height) return this;
              for (var r3 in this.emit("resize"), this.elements) {
                var i3 = this.elements[r3];
                i3.style.width = this.width + "px", i3.style.height = this.height + "px";
              }
              for (var r3 in this.canvasContexts) this.elements[r3].setAttribute("width", this.width * this.pixelRatio + "px"), this.elements[r3].setAttribute("height", this.height * this.pixelRatio + "px"), 1 !== this.pixelRatio && this.canvasContexts[r3].scale(this.pixelRatio, this.pixelRatio);
              for (var r3 in this.webGLContexts) this.elements[r3].setAttribute("width", this.width * this.pixelRatio + "px"), this.elements[r3].setAttribute("height", this.height * this.pixelRatio + "px"), this.webGLContexts[r3].viewport(0, 0, this.width * this.pixelRatio, this.height * this.pixelRatio);
              return this;
            }, e3.prototype.clear = function() {
              return this.webGLContexts.nodes.clear(this.webGLContexts.nodes.COLOR_BUFFER_BIT), this.webGLContexts.edges.clear(this.webGLContexts.edges.COLOR_BUFFER_BIT), this.webGLContexts.hoverNodes.clear(this.webGLContexts.hoverNodes.COLOR_BUFFER_BIT), this.canvasContexts.labels.clearRect(0, 0, this.width, this.height), this.canvasContexts.hovers.clearRect(0, 0, this.width, this.height), this.canvasContexts.edgeLabels.clearRect(0, 0, this.width, this.height), this;
            }, e3.prototype.refresh = function() {
              return this.needToProcess = true, this._refresh(), this;
            }, e3.prototype.scheduleRefresh = function() {
              return this.needToProcess = true, this._scheduleRefresh(), this;
            }, e3.prototype.getViewportZoomedState = function(t4, e4) {
              var r3 = this.camera.getState(), i3 = r3.ratio, n2 = r3.angle, o2 = r3.x, a2 = r3.y, s2 = e4 / i3, h2 = { x: this.width / 2, y: this.height / 2 }, l2 = this.viewportToFramedGraph(t4), c2 = this.viewportToFramedGraph(h2);
              return { angle: n2, x: (l2.x - c2.x) * (1 - s2) + o2, y: (l2.y - c2.y) * (1 - s2) + a2, ratio: e4 };
            }, e3.prototype.viewRectangle = function() {
              var t4 = 0 * this.width / 8, e4 = 0 * this.height / 8, r3 = this.viewportToFramedGraph({ x: 0 - t4, y: 0 - e4 }), i3 = this.viewportToFramedGraph({ x: this.width + t4, y: 0 - e4 }), n2 = this.viewportToFramedGraph({ x: 0, y: this.height + e4 });
              return { x1: r3.x, y1: r3.y, x2: i3.x, y2: i3.y, height: i3.y - n2.y };
            }, e3.prototype.framedGraphToViewport = function(t4, e4) {
              void 0 === e4 && (e4 = {});
              var r3 = !!e4.cameraState || !!e4.viewportDimensions || !!e4.graphDimensions, i3 = e4.matrix ? e4.matrix : r3 ? (0, f.matrixFromCamera)(e4.cameraState || this.camera.getState(), e4.viewportDimensions || this.getDimensions(), e4.graphDimensions || this.getGraphDimensions(), e4.padding || this.getSetting("stagePadding") || 0) : this.matrix, n2 = (0, m.multiplyVec2)(i3, t4);
              return { x: (1 + n2.x) * this.width / 2, y: (1 - n2.y) * this.height / 2 };
            }, e3.prototype.viewportToFramedGraph = function(t4, e4) {
              void 0 === e4 && (e4 = {});
              var r3 = !!e4.cameraState || !!e4.viewportDimensions || !e4.graphDimensions, i3 = e4.matrix ? e4.matrix : r3 ? (0, f.matrixFromCamera)(e4.cameraState || this.camera.getState(), e4.viewportDimensions || this.getDimensions(), e4.graphDimensions || this.getGraphDimensions(), e4.padding || this.getSetting("stagePadding") || 0, true) : this.invMatrix, n2 = (0, m.multiplyVec2)(i3, { x: t4.x / this.width * 2 - 1, y: 1 - t4.y / this.height * 2 });
              return isNaN(n2.x) && (n2.x = 0), isNaN(n2.y) && (n2.y = 0), n2;
            }, e3.prototype.viewportToGraph = function(t4, e4) {
              return void 0 === e4 && (e4 = {}), this.normalizationFunction.inverse(this.viewportToFramedGraph(t4, e4));
            }, e3.prototype.graphToViewport = function(t4, e4) {
              return void 0 === e4 && (e4 = {}), this.framedGraphToViewport(this.normalizationFunction(t4), e4);
            }, e3.prototype.getBBox = function() {
              return (0, f.graphExtent)(this.graph);
            }, e3.prototype.getCustomBBox = function() {
              return this.customBBox;
            }, e3.prototype.setCustomBBox = function(t4) {
              return this.customBBox = t4, this._scheduleRefresh(), this;
            }, e3.prototype.kill = function() {
              this.emit("kill"), this.removeAllListeners(), this.camera.removeListener("updated", this.activeListeners.camera), window.removeEventListener("resize", this.activeListeners.handleResize), this.mouseCaptor.kill(), this.touchCaptor.kill(), this.unbindGraphHandlers(), this.quadtree = new u.default(), this.nodeDataCache = {}, this.edgeDataCache = {}, this.nodesWithForcedLabels = [], this.edgesWithForcedLabels = [], this.highlightedNodes.clear(), this.renderFrame && ((0, f.cancelFrame)(this.renderFrame), this.renderFrame = null), this.renderHighlightedNodesFrame && ((0, f.cancelFrame)(this.renderHighlightedNodesFrame), this.renderHighlightedNodesFrame = null);
              for (var t4 = this.container; t4.firstChild; ) t4.removeChild(t4.firstChild);
            }, e3.prototype.scaleSize = function(t4) {
              return t4 / this.cameraSizeRatio;
            }, e3.prototype.getCanvases = function() {
              return o({}, this.elements);
            }, e3;
          }(d.TypedEventEmitter);
          e2.default = x;
        }, 699: function(t2, e2, r2) {
          "use strict";
          var i2, n = this && this.__extends || (i2 = function(t3, e3) {
            return i2 = Object.setPrototypeOf || { __proto__: [] } instanceof Array && function(t4, e4) {
              t4.__proto__ = e4;
            } || function(t4, e4) {
              for (var r3 in e4) Object.prototype.hasOwnProperty.call(e4, r3) && (t4[r3] = e4[r3]);
            }, i2(t3, e3);
          }, function(t3, e3) {
            if ("function" != typeof e3 && null !== e3) throw new TypeError("Class extends value " + String(e3) + " is not a constructor or null");
            function r3() {
              this.constructor = t3;
            }
            i2(t3, e3), t3.prototype = null === e3 ? Object.create(e3) : (r3.prototype = e3.prototype, new r3());
          });
          Object.defineProperty(e2, "__esModule", { value: true }), e2.TypedEventEmitter = void 0;
          var o = function(t3) {
            function e3() {
              var e4 = t3.call(this) || this;
              return e4.rawEmitter = e4, e4;
            }
            return n(e3, t3), e3;
          }(r2(187).EventEmitter);
          e2.TypedEventEmitter = o;
        }, 751: function(t2, e2, r2) {
          "use strict";
          var i2 = this && this.__importDefault || function(t3) {
            return t3 && t3.__esModule ? t3 : { default: t3 };
          };
          Object.defineProperty(e2, "__esModule", { value: true }), e2.animateNodes = e2.ANIMATE_DEFAULTS = void 0;
          var n = r2(928), o = i2(r2(358));
          e2.ANIMATE_DEFAULTS = { easing: "quadraticInOut", duration: 150 }, e2.animateNodes = function(t3, r3, i3, a) {
            var s = Object.assign({}, e2.ANIMATE_DEFAULTS, i3), h = "function" == typeof s.easing ? s.easing : o.default[s.easing], l = Date.now(), c = {};
            for (var u in r3) {
              var d = r3[u];
              for (var f in c[u] = {}, d) c[u][f] = t3.getNodeAttribute(u, f);
            }
            var p = null, g = function() {
              p = null;
              var e3 = (Date.now() - l) / s.duration;
              if (e3 >= 1) {
                for (var i4 in r3) {
                  var o2 = r3[i4];
                  for (var u2 in o2) t3.setNodeAttribute(i4, u2, o2[u2]);
                }
                "function" == typeof a && a();
              } else {
                for (var i4 in e3 = h(e3), r3) {
                  o2 = r3[i4];
                  var d2 = c[i4];
                  for (var u2 in o2) t3.setNodeAttribute(i4, u2, o2[u2] * e3 + d2[u2] * (1 - e3));
                }
                p = (0, n.requestFrame)(g);
              }
            };
            return g(), function() {
              p && (0, n.cancelFrame)(p);
            };
          };
        }, 634: (t2, e2) => {
          "use strict";
          Object.defineProperty(e2, "__esModule", { value: true }), e2.HTML_COLORS = void 0, e2.HTML_COLORS = { black: "#000000", silver: "#C0C0C0", gray: "#808080", grey: "#808080", white: "#FFFFFF", maroon: "#800000", red: "#FF0000", purple: "#800080", fuchsia: "#FF00FF", green: "#008000", lime: "#00FF00", olive: "#808000", yellow: "#FFFF00", navy: "#000080", blue: "#0000FF", teal: "#008080", aqua: "#00FFFF", darkblue: "#00008B", mediumblue: "#0000CD", darkgreen: "#006400", darkcyan: "#008B8B", deepskyblue: "#00BFFF", darkturquoise: "#00CED1", mediumspringgreen: "#00FA9A", springgreen: "#00FF7F", cyan: "#00FFFF", midnightblue: "#191970", dodgerblue: "#1E90FF", lightseagreen: "#20B2AA", forestgreen: "#228B22", seagreen: "#2E8B57", darkslategray: "#2F4F4F", darkslategrey: "#2F4F4F", limegreen: "#32CD32", mediumseagreen: "#3CB371", turquoise: "#40E0D0", royalblue: "#4169E1", steelblue: "#4682B4", darkslateblue: "#483D8B", mediumturquoise: "#48D1CC", indigo: "#4B0082", darkolivegreen: "#556B2F", cadetblue: "#5F9EA0", cornflowerblue: "#6495ED", rebeccapurple: "#663399", mediumaquamarine: "#66CDAA", dimgray: "#696969", dimgrey: "#696969", slateblue: "#6A5ACD", olivedrab: "#6B8E23", slategray: "#708090", slategrey: "#708090", lightslategray: "#778899", lightslategrey: "#778899", mediumslateblue: "#7B68EE", lawngreen: "#7CFC00", chartreuse: "#7FFF00", aquamarine: "#7FFFD4", skyblue: "#87CEEB", lightskyblue: "#87CEFA", blueviolet: "#8A2BE2", darkred: "#8B0000", darkmagenta: "#8B008B", saddlebrown: "#8B4513", darkseagreen: "#8FBC8F", lightgreen: "#90EE90", mediumpurple: "#9370DB", darkviolet: "#9400D3", palegreen: "#98FB98", darkorchid: "#9932CC", yellowgreen: "#9ACD32", sienna: "#A0522D", brown: "#A52A2A", darkgray: "#A9A9A9", darkgrey: "#A9A9A9", lightblue: "#ADD8E6", greenyellow: "#ADFF2F", paleturquoise: "#AFEEEE", lightsteelblue: "#B0C4DE", powderblue: "#B0E0E6", firebrick: "#B22222", darkgoldenrod: "#B8860B", mediumorchid: "#BA55D3", rosybrown: "#BC8F8F", darkkhaki: "#BDB76B", mediumvioletred: "#C71585", indianred: "#CD5C5C", peru: "#CD853F", chocolate: "#D2691E", tan: "#D2B48C", lightgray: "#D3D3D3", lightgrey: "#D3D3D3", thistle: "#D8BFD8", orchid: "#DA70D6", goldenrod: "#DAA520", palevioletred: "#DB7093", crimson: "#DC143C", gainsboro: "#DCDCDC", plum: "#DDA0DD", burlywood: "#DEB887", lightcyan: "#E0FFFF", lavender: "#E6E6FA", darksalmon: "#E9967A", violet: "#EE82EE", palegoldenrod: "#EEE8AA", lightcoral: "#F08080", khaki: "#F0E68C", aliceblue: "#F0F8FF", honeydew: "#F0FFF0", azure: "#F0FFFF", sandybrown: "#F4A460", wheat: "#F5DEB3", beige: "#F5F5DC", whitesmoke: "#F5F5F5", mintcream: "#F5FFFA", ghostwhite: "#F8F8FF", salmon: "#FA8072", antiquewhite: "#FAEBD7", linen: "#FAF0E6", lightgoldenrodyellow: "#FAFAD2", oldlace: "#FDF5E6", magenta: "#FF00FF", deeppink: "#FF1493", orangered: "#FF4500", tomato: "#FF6347", hotpink: "#FF69B4", coral: "#FF7F50", darkorange: "#FF8C00", lightsalmon: "#FFA07A", orange: "#FFA500", lightpink: "#FFB6C1", pink: "#FFC0CB", gold: "#FFD700", peachpuff: "#FFDAB9", navajowhite: "#FFDEAD", moccasin: "#FFE4B5", bisque: "#FFE4C4", mistyrose: "#FFE4E1", blanchedalmond: "#FFEBCD", papayawhip: "#FFEFD5", lavenderblush: "#FFF0F5", seashell: "#FFF5EE", cornsilk: "#FFF8DC", lemonchiffon: "#FFFACD", floralwhite: "#FFFAF0", snow: "#FFFAFA", lightyellow: "#FFFFE0", ivory: "#FFFFF0" };
        }, 358: (t2, e2) => {
          "use strict";
          Object.defineProperty(e2, "__esModule", { value: true }), e2.cubicInOut = e2.cubicOut = e2.cubicIn = e2.quadraticInOut = e2.quadraticOut = e2.quadraticIn = e2.linear = void 0, e2.linear = function(t3) {
            return t3;
          }, e2.quadraticIn = function(t3) {
            return t3 * t3;
          }, e2.quadraticOut = function(t3) {
            return t3 * (2 - t3);
          }, e2.quadraticInOut = function(t3) {
            return (t3 *= 2) < 1 ? 0.5 * t3 * t3 : -0.5 * (--t3 * (t3 - 2) - 1);
          }, e2.cubicIn = function(t3) {
            return t3 * t3 * t3;
          }, e2.cubicOut = function(t3) {
            return --t3 * t3 * t3 + 1;
          }, e2.cubicInOut = function(t3) {
            return (t3 *= 2) < 1 ? 0.5 * t3 * t3 * t3 : 0.5 * ((t3 -= 2) * t3 * t3 + 2);
          };
          var r2 = { linear: e2.linear, quadraticIn: e2.quadraticIn, quadraticOut: e2.quadraticOut, quadraticInOut: e2.quadraticInOut, cubicIn: e2.cubicIn, cubicOut: e2.cubicOut, cubicInOut: e2.cubicInOut };
          e2.default = r2;
        }, 628: (t2, e2) => {
          "use strict";
          Object.defineProperty(e2, "__esModule", { value: true }), e2.doEdgeCollideWithPoint = e2.isPixelColored = void 0, e2.isPixelColored = function(t3, e3, r2) {
            var i2 = new Uint8Array(4);
            return t3.readPixels(e3, t3.drawingBufferHeight - r2, 1, 1, t3.RGBA, t3.UNSIGNED_BYTE, i2), i2[3] > 0;
          }, e2.doEdgeCollideWithPoint = function(t3, e3, r2, i2, n, o, a) {
            return !(t3 < r2 - a && t3 < n - a || e3 < i2 - a && e3 < o - a || t3 > r2 + a && t3 > n + a || e3 > i2 + a && e3 > o + a || !(Math.abs((n - r2) * (i2 - e3) - (r2 - t3) * (o - i2)) / Math.sqrt(Math.pow(n - r2, 2) + Math.pow(o - i2, 2)) < a / 2));
          };
        }, 928: function(t2, e2, r2) {
          "use strict";
          var i2 = this && this.__read || function(t3, e3) {
            var r3 = "function" == typeof Symbol && t3[Symbol.iterator];
            if (!r3) return t3;
            var i3, n2, o2 = r3.call(t3), a2 = [];
            try {
              for (; (void 0 === e3 || e3-- > 0) && !(i3 = o2.next()).done; ) a2.push(i3.value);
            } catch (t4) {
              n2 = { error: t4 };
            } finally {
              try {
                i3 && !i3.done && (r3 = o2.return) && r3.call(o2);
              } finally {
                if (n2) throw n2.error;
              }
            }
            return a2;
          }, n = this && this.__importDefault || function(t3) {
            return t3 && t3.__esModule ? t3 : { default: t3 };
          };
          Object.defineProperty(e2, "__esModule", { value: true }), e2.validateGraph = e2.canUse32BitsIndices = e2.extractPixel = e2.getMatrixImpact = e2.matrixFromCamera = e2.getCorrectionRatio = e2.floatColor = e2.floatArrayColor = e2.parseColor = e2.zIndexOrdering = e2.createNormalizationFunction = e2.graphExtent = e2.getPixelRatio = e2.createElement = e2.cancelFrame = e2.requestFrame = e2.assignDeep = e2.assign = e2.isPlainObject = void 0;
          var o = n(r2(186)), a = r2(700), s = r2(634);
          function h(t3) {
            return "object" == typeof t3 && null !== t3 && t3.constructor === Object;
          }
          e2.isPlainObject = h, e2.assign = function(t3) {
            for (var e3 = [], r3 = 1; r3 < arguments.length; r3++) e3[r3 - 1] = arguments[r3];
            t3 = t3 || {};
            for (var i3 = 0, n2 = e3.length; i3 < n2; i3++) {
              var o2 = e3[i3];
              o2 && Object.assign(t3, o2);
            }
            return t3;
          }, e2.assignDeep = function t3(e3) {
            for (var r3 = [], i3 = 1; i3 < arguments.length; i3++) r3[i3 - 1] = arguments[i3];
            e3 = e3 || {};
            for (var n2 = 0, o2 = r3.length; n2 < o2; n2++) {
              var a2 = r3[n2];
              if (a2) for (var s2 in a2) h(a2[s2]) ? e3[s2] = t3(e3[s2], a2[s2]) : e3[s2] = a2[s2];
            }
            return e3;
          }, e2.requestFrame = "undefined" != typeof requestAnimationFrame ? function(t3) {
            return requestAnimationFrame(t3);
          } : function(t3) {
            return setTimeout(t3, 0);
          }, e2.cancelFrame = "undefined" != typeof cancelAnimationFrame ? function(t3) {
            return cancelAnimationFrame(t3);
          } : function(t3) {
            return clearTimeout(t3);
          }, e2.createElement = function(t3, e3, r3) {
            var i3 = document.createElement(t3);
            if (e3) for (var n2 in e3) i3.style[n2] = e3[n2];
            if (r3) for (var n2 in r3) i3.setAttribute(n2, r3[n2]);
            return i3;
          }, e2.getPixelRatio = function() {
            return void 0 !== window.devicePixelRatio ? window.devicePixelRatio : 1;
          }, e2.graphExtent = function(t3) {
            if (!t3.order) return { x: [0, 1], y: [0, 1] };
            var e3 = 1 / 0, r3 = -1 / 0, i3 = 1 / 0, n2 = -1 / 0;
            return t3.forEachNode(function(t4, o2) {
              var a2 = o2.x, s2 = o2.y;
              a2 < e3 && (e3 = a2), a2 > r3 && (r3 = a2), s2 < i3 && (i3 = s2), s2 > n2 && (n2 = s2);
            }), { x: [e3, r3], y: [i3, n2] };
          }, e2.createNormalizationFunction = function(t3) {
            var e3 = i2(t3.x, 2), r3 = e3[0], n2 = e3[1], o2 = i2(t3.y, 2), a2 = o2[0], s2 = o2[1], h2 = Math.max(n2 - r3, s2 - a2), l2 = (n2 + r3) / 2, c2 = (s2 + a2) / 2;
            (0 === h2 || Math.abs(h2) === 1 / 0 || isNaN(h2)) && (h2 = 1), isNaN(l2) && (l2 = 0), isNaN(c2) && (c2 = 0);
            var u2 = function(t4) {
              return { x: 0.5 + (t4.x - l2) / h2, y: 0.5 + (t4.y - c2) / h2 };
            };
            return u2.applyTo = function(t4) {
              t4.x = 0.5 + (t4.x - l2) / h2, t4.y = 0.5 + (t4.y - c2) / h2;
            }, u2.inverse = function(t4) {
              return { x: l2 + h2 * (t4.x - 0.5), y: c2 + h2 * (t4.y - 0.5) };
            }, u2.ratio = h2, u2;
          }, e2.zIndexOrdering = function(t3, e3, r3) {
            return r3.sort(function(t4, r4) {
              var i3 = e3(t4) || 0, n2 = e3(r4) || 0;
              return i3 < n2 ? -1 : i3 > n2 ? 1 : 0;
            });
          };
          var l = new Int8Array(4), c = new Int32Array(l.buffer, 0, 1), u = new Float32Array(l.buffer, 0, 1), d = /^\s*rgba?\s*\(/, f = /^\s*rgba?\s*\(\s*([0-9]*)\s*,\s*([0-9]*)\s*,\s*([0-9]*)(?:\s*,\s*(.*)?)?\)\s*$/;
          function p(t3) {
            var e3 = 0, r3 = 0, i3 = 0, n2 = 1;
            if ("#" === t3[0]) 4 === t3.length ? (e3 = parseInt(t3.charAt(1) + t3.charAt(1), 16), r3 = parseInt(t3.charAt(2) + t3.charAt(2), 16), i3 = parseInt(t3.charAt(3) + t3.charAt(3), 16)) : (e3 = parseInt(t3.charAt(1) + t3.charAt(2), 16), r3 = parseInt(t3.charAt(3) + t3.charAt(4), 16), i3 = parseInt(t3.charAt(5) + t3.charAt(6), 16)), 9 === t3.length && (n2 = parseInt(t3.charAt(7) + t3.charAt(8), 16) / 255);
            else if (d.test(t3)) {
              var o2 = t3.match(f);
              o2 && (e3 = +o2[1], r3 = +o2[2], i3 = +o2[3], o2[4] && (n2 = +o2[4]));
            }
            return { r: e3, g: r3, b: i3, a: n2 };
          }
          e2.parseColor = p;
          var g = {};
          for (var v in s.HTML_COLORS) g[v] = m(s.HTML_COLORS[v]), g[s.HTML_COLORS[v]] = g[v];
          function m(t3) {
            if (void 0 !== g[t3]) return g[t3];
            var e3 = p(t3), r3 = e3.r, i3 = e3.g, n2 = e3.b, o2 = e3.a;
            o2 = 255 * o2 | 0, c[0] = 4278190079 & (o2 << 24 | n2 << 16 | i3 << 8 | r3);
            var a2 = u[0];
            return g[t3] = a2, a2;
          }
          function y(t3, e3) {
            var r3 = t3.height / t3.width, i3 = e3.height / e3.width;
            return r3 < 1 && i3 > 1 || r3 > 1 && i3 < 1 ? 1 : Math.min(Math.max(i3, 1 / i3), Math.max(1 / r3, r3));
          }
          e2.floatArrayColor = function(t3) {
            var e3 = p(t3 = s.HTML_COLORS[t3] || t3), r3 = e3.r, i3 = e3.g, n2 = e3.b, o2 = e3.a;
            return new Float32Array([r3 / 255, i3 / 255, n2 / 255, o2]);
          }, e2.floatColor = m, e2.getCorrectionRatio = y, e2.matrixFromCamera = function(t3, e3, r3, i3, n2) {
            var o2 = t3.angle, s2 = t3.ratio, h2 = t3.x, l2 = t3.y, c2 = e3.width, u2 = e3.height, d2 = (0, a.identity)(), f2 = Math.min(c2, u2) - 2 * i3, p2 = y(e3, r3);
            return n2 ? ((0, a.multiply)(d2, (0, a.translate)((0, a.identity)(), h2, l2)), (0, a.multiply)(d2, (0, a.scale)((0, a.identity)(), s2)), (0, a.multiply)(d2, (0, a.rotate)((0, a.identity)(), o2)), (0, a.multiply)(d2, (0, a.scale)((0, a.identity)(), c2 / f2 / 2 / p2, u2 / f2 / 2 / p2))) : ((0, a.multiply)(d2, (0, a.scale)((0, a.identity)(), f2 / c2 * 2 * p2, f2 / u2 * 2 * p2)), (0, a.multiply)(d2, (0, a.rotate)((0, a.identity)(), -o2)), (0, a.multiply)(d2, (0, a.scale)((0, a.identity)(), 1 / s2)), (0, a.multiply)(d2, (0, a.translate)((0, a.identity)(), -h2, -l2))), d2;
          }, e2.getMatrixImpact = function(t3, e3, r3) {
            var i3 = (0, a.multiplyVec2)(t3, { x: Math.cos(e3.angle), y: Math.sin(e3.angle) }, 0), n2 = i3.x, o2 = i3.y;
            return 1 / Math.sqrt(Math.pow(n2, 2) + Math.pow(o2, 2)) / r3.width;
          }, e2.extractPixel = function(t3, e3, r3, i3) {
            var n2 = i3 || new Uint8Array(4);
            return t3.readPixels(e3, r3, 1, 1, t3.RGBA, t3.UNSIGNED_BYTE, n2), n2;
          }, e2.canUse32BitsIndices = function(t3) {
            return "undefined" != typeof WebGL2RenderingContext && t3 instanceof WebGL2RenderingContext || !!t3.getExtension("OES_element_index_uint");
          }, e2.validateGraph = function(t3) {
            if (!(0, o.default)(t3)) throw new Error("Sigma: invalid graph instance.");
            t3.forEachNode(function(t4, e3) {
              if (!Number.isFinite(e3.x) || !Number.isFinite(e3.y)) throw new Error("Sigma: Coordinates of node ".concat(t4, " are invalid. A node must have a numeric 'x' and 'y' attribute."));
            });
          };
        }, 700: (t2, e2) => {
          "use strict";
          Object.defineProperty(e2, "__esModule", { value: true }), e2.multiplyVec2 = e2.multiply = e2.translate = e2.rotate = e2.scale = e2.identity = void 0, e2.identity = function() {
            return Float32Array.of(1, 0, 0, 0, 1, 0, 0, 0, 1);
          }, e2.scale = function(t3, e3, r2) {
            return t3[0] = e3, t3[4] = "number" == typeof r2 ? r2 : e3, t3;
          }, e2.rotate = function(t3, e3) {
            var r2 = Math.sin(e3), i2 = Math.cos(e3);
            return t3[0] = i2, t3[1] = r2, t3[3] = -r2, t3[4] = i2, t3;
          }, e2.translate = function(t3, e3, r2) {
            return t3[6] = e3, t3[7] = r2, t3;
          }, e2.multiply = function(t3, e3) {
            var r2 = t3[0], i2 = t3[1], n = t3[2], o = t3[3], a = t3[4], s = t3[5], h = t3[6], l = t3[7], c = t3[8], u = e3[0], d = e3[1], f = e3[2], p = e3[3], g = e3[4], v = e3[5], m = e3[6], y = e3[7], b = e3[8];
            return t3[0] = u * r2 + d * o + f * h, t3[1] = u * i2 + d * a + f * l, t3[2] = u * n + d * s + f * c, t3[3] = p * r2 + g * o + v * h, t3[4] = p * i2 + g * a + v * l, t3[5] = p * n + g * s + v * c, t3[6] = m * r2 + y * o + b * h, t3[7] = m * i2 + y * a + b * l, t3[8] = m * n + y * s + b * c, t3;
          }, e2.multiplyVec2 = function(t3, e3, r2) {
            void 0 === r2 && (r2 = 1);
            var i2 = t3[0], n = t3[1], o = t3[3], a = t3[4], s = t3[6], h = t3[7], l = e3.x, c = e3.y;
            return { x: l * i2 + c * o + s * r2, y: l * n + c * a + h * r2 };
          };
        } }, e = {};
        function r(i2) {
          var n = e[i2];
          if (void 0 !== n) return n.exports;
          var o = e[i2] = { exports: {} };
          return t[i2].call(o.exports, o, o.exports, r), o.exports;
        }
        r.d = (t2, e2) => {
          for (var i2 in e2) r.o(e2, i2) && !r.o(t2, i2) && Object.defineProperty(t2, i2, { enumerable: true, get: e2[i2] });
        }, r.o = (t2, e2) => Object.prototype.hasOwnProperty.call(t2, e2), r.r = (t2) => {
          "undefined" != typeof Symbol && Symbol.toStringTag && Object.defineProperty(t2, Symbol.toStringTag, { value: "Module" }), Object.defineProperty(t2, "__esModule", { value: true });
        };
        var i = r(265);
        Sigma2 = i;
      })();
    }
  });

  // ../deps/phoenix/priv/static/phoenix.mjs
  var closure = (value) => {
    if (typeof value === "function") {
      return value;
    } else {
      let closure22 = function() {
        return value;
      };
      return closure22;
    }
  };
  var globalSelf = typeof self !== "undefined" ? self : null;
  var phxWindow = typeof window !== "undefined" ? window : null;
  var global = globalSelf || phxWindow || globalThis;
  var DEFAULT_VSN = "2.0.0";
  var SOCKET_STATES = { connecting: 0, open: 1, closing: 2, closed: 3 };
  var DEFAULT_TIMEOUT = 1e4;
  var WS_CLOSE_NORMAL = 1e3;
  var CHANNEL_STATES = {
    closed: "closed",
    errored: "errored",
    joined: "joined",
    joining: "joining",
    leaving: "leaving"
  };
  var CHANNEL_EVENTS = {
    close: "phx_close",
    error: "phx_error",
    join: "phx_join",
    reply: "phx_reply",
    leave: "phx_leave"
  };
  var TRANSPORTS = {
    longpoll: "longpoll",
    websocket: "websocket"
  };
  var XHR_STATES = {
    complete: 4
  };
  var AUTH_TOKEN_PREFIX = "base64url.bearer.phx.";
  var Push = class {
    constructor(channel, event, payload, timeout) {
      this.channel = channel;
      this.event = event;
      this.payload = payload || function() {
        return {};
      };
      this.receivedResp = null;
      this.timeout = timeout;
      this.timeoutTimer = null;
      this.recHooks = [];
      this.sent = false;
    }
    /**
     *
     * @param {number} timeout
     */
    resend(timeout) {
      this.timeout = timeout;
      this.reset();
      this.send();
    }
    /**
     *
     */
    send() {
      if (this.hasReceived("timeout")) {
        return;
      }
      this.startTimeout();
      this.sent = true;
      this.channel.socket.push({
        topic: this.channel.topic,
        event: this.event,
        payload: this.payload(),
        ref: this.ref,
        join_ref: this.channel.joinRef()
      });
    }
    /**
     *
     * @param {*} status
     * @param {*} callback
     */
    receive(status, callback) {
      if (this.hasReceived(status)) {
        callback(this.receivedResp.response);
      }
      this.recHooks.push({ status, callback });
      return this;
    }
    /**
     * @private
     */
    reset() {
      this.cancelRefEvent();
      this.ref = null;
      this.refEvent = null;
      this.receivedResp = null;
      this.sent = false;
    }
    /**
     * @private
     */
    matchReceive({ status, response, _ref }) {
      this.recHooks.filter((h) => h.status === status).forEach((h) => h.callback(response));
    }
    /**
     * @private
     */
    cancelRefEvent() {
      if (!this.refEvent) {
        return;
      }
      this.channel.off(this.refEvent);
    }
    /**
     * @private
     */
    cancelTimeout() {
      clearTimeout(this.timeoutTimer);
      this.timeoutTimer = null;
    }
    /**
     * @private
     */
    startTimeout() {
      if (this.timeoutTimer) {
        this.cancelTimeout();
      }
      this.ref = this.channel.socket.makeRef();
      this.refEvent = this.channel.replyEventName(this.ref);
      this.channel.on(this.refEvent, (payload) => {
        this.cancelRefEvent();
        this.cancelTimeout();
        this.receivedResp = payload;
        this.matchReceive(payload);
      });
      this.timeoutTimer = setTimeout(() => {
        this.trigger("timeout", {});
      }, this.timeout);
    }
    /**
     * @private
     */
    hasReceived(status) {
      return this.receivedResp && this.receivedResp.status === status;
    }
    /**
     * @private
     */
    trigger(status, response) {
      this.channel.trigger(this.refEvent, { status, response });
    }
  };
  var Timer = class {
    constructor(callback, timerCalc) {
      this.callback = callback;
      this.timerCalc = timerCalc;
      this.timer = null;
      this.tries = 0;
    }
    reset() {
      this.tries = 0;
      clearTimeout(this.timer);
    }
    /**
     * Cancels any previous scheduleTimeout and schedules callback
     */
    scheduleTimeout() {
      clearTimeout(this.timer);
      this.timer = setTimeout(() => {
        this.tries = this.tries + 1;
        this.callback();
      }, this.timerCalc(this.tries + 1));
    }
  };
  var Channel = class {
    constructor(topic, params, socket) {
      this.state = CHANNEL_STATES.closed;
      this.topic = topic;
      this.params = closure(params || {});
      this.socket = socket;
      this.bindings = [];
      this.bindingRef = 0;
      this.timeout = this.socket.timeout;
      this.joinedOnce = false;
      this.joinPush = new Push(this, CHANNEL_EVENTS.join, this.params, this.timeout);
      this.pushBuffer = [];
      this.stateChangeRefs = [];
      this.rejoinTimer = new Timer(() => {
        if (this.socket.isConnected()) {
          this.rejoin();
        }
      }, this.socket.rejoinAfterMs);
      this.stateChangeRefs.push(this.socket.onError(() => this.rejoinTimer.reset()));
      this.stateChangeRefs.push(
        this.socket.onOpen(() => {
          this.rejoinTimer.reset();
          if (this.isErrored()) {
            this.rejoin();
          }
        })
      );
      this.joinPush.receive("ok", () => {
        this.state = CHANNEL_STATES.joined;
        this.rejoinTimer.reset();
        this.pushBuffer.forEach((pushEvent) => pushEvent.send());
        this.pushBuffer = [];
      });
      this.joinPush.receive("error", () => {
        this.state = CHANNEL_STATES.errored;
        if (this.socket.isConnected()) {
          this.rejoinTimer.scheduleTimeout();
        }
      });
      this.onClose(() => {
        this.rejoinTimer.reset();
        if (this.socket.hasLogger()) this.socket.log("channel", `close ${this.topic} ${this.joinRef()}`);
        this.state = CHANNEL_STATES.closed;
        this.socket.remove(this);
      });
      this.onError((reason) => {
        if (this.socket.hasLogger()) this.socket.log("channel", `error ${this.topic}`, reason);
        if (this.isJoining()) {
          this.joinPush.reset();
        }
        this.state = CHANNEL_STATES.errored;
        if (this.socket.isConnected()) {
          this.rejoinTimer.scheduleTimeout();
        }
      });
      this.joinPush.receive("timeout", () => {
        if (this.socket.hasLogger()) this.socket.log("channel", `timeout ${this.topic} (${this.joinRef()})`, this.joinPush.timeout);
        let leavePush = new Push(this, CHANNEL_EVENTS.leave, closure({}), this.timeout);
        leavePush.send();
        this.state = CHANNEL_STATES.errored;
        this.joinPush.reset();
        if (this.socket.isConnected()) {
          this.rejoinTimer.scheduleTimeout();
        }
      });
      this.on(CHANNEL_EVENTS.reply, (payload, ref) => {
        this.trigger(this.replyEventName(ref), payload);
      });
    }
    /**
     * Join the channel
     * @param {integer} timeout
     * @returns {Push}
     */
    join(timeout = this.timeout) {
      if (this.joinedOnce) {
        throw new Error("tried to join multiple times. 'join' can only be called a single time per channel instance");
      } else {
        this.timeout = timeout;
        this.joinedOnce = true;
        this.rejoin();
        return this.joinPush;
      }
    }
    /**
     * Hook into channel close
     * @param {Function} callback
     */
    onClose(callback) {
      this.on(CHANNEL_EVENTS.close, callback);
    }
    /**
     * Hook into channel errors
     * @param {Function} callback
     */
    onError(callback) {
      return this.on(CHANNEL_EVENTS.error, (reason) => callback(reason));
    }
    /**
     * Subscribes on channel events
     *
     * Subscription returns a ref counter, which can be used later to
     * unsubscribe the exact event listener
     *
     * @example
     * const ref1 = channel.on("event", do_stuff)
     * const ref2 = channel.on("event", do_other_stuff)
     * channel.off("event", ref1)
     * // Since unsubscription, do_stuff won't fire,
     * // while do_other_stuff will keep firing on the "event"
     *
     * @param {string} event
     * @param {Function} callback
     * @returns {integer} ref
     */
    on(event, callback) {
      let ref = this.bindingRef++;
      this.bindings.push({ event, ref, callback });
      return ref;
    }
    /**
     * Unsubscribes off of channel events
     *
     * Use the ref returned from a channel.on() to unsubscribe one
     * handler, or pass nothing for the ref to unsubscribe all
     * handlers for the given event.
     *
     * @example
     * // Unsubscribe the do_stuff handler
     * const ref1 = channel.on("event", do_stuff)
     * channel.off("event", ref1)
     *
     * // Unsubscribe all handlers from event
     * channel.off("event")
     *
     * @param {string} event
     * @param {integer} ref
     */
    off(event, ref) {
      this.bindings = this.bindings.filter((bind) => {
        return !(bind.event === event && (typeof ref === "undefined" || ref === bind.ref));
      });
    }
    /**
     * @private
     */
    canPush() {
      return this.socket.isConnected() && this.isJoined();
    }
    /**
     * Sends a message `event` to phoenix with the payload `payload`.
     * Phoenix receives this in the `handle_in(event, payload, socket)`
     * function. if phoenix replies or it times out (default 10000ms),
     * then optionally the reply can be received.
     *
     * @example
     * channel.push("event")
     *   .receive("ok", payload => console.log("phoenix replied:", payload))
     *   .receive("error", err => console.log("phoenix errored", err))
     *   .receive("timeout", () => console.log("timed out pushing"))
     * @param {string} event
     * @param {Object} payload
     * @param {number} [timeout]
     * @returns {Push}
     */
    push(event, payload, timeout = this.timeout) {
      payload = payload || {};
      if (!this.joinedOnce) {
        throw new Error(`tried to push '${event}' to '${this.topic}' before joining. Use channel.join() before pushing events`);
      }
      let pushEvent = new Push(this, event, function() {
        return payload;
      }, timeout);
      if (this.canPush()) {
        pushEvent.send();
      } else {
        pushEvent.startTimeout();
        this.pushBuffer.push(pushEvent);
      }
      return pushEvent;
    }
    /** Leaves the channel
     *
     * Unsubscribes from server events, and
     * instructs channel to terminate on server
     *
     * Triggers onClose() hooks
     *
     * To receive leave acknowledgements, use the `receive`
     * hook to bind to the server ack, ie:
     *
     * @example
     * channel.leave().receive("ok", () => alert("left!") )
     *
     * @param {integer} timeout
     * @returns {Push}
     */
    leave(timeout = this.timeout) {
      this.rejoinTimer.reset();
      this.joinPush.cancelTimeout();
      this.state = CHANNEL_STATES.leaving;
      let onClose = () => {
        if (this.socket.hasLogger()) this.socket.log("channel", `leave ${this.topic}`);
        this.trigger(CHANNEL_EVENTS.close, "leave");
      };
      let leavePush = new Push(this, CHANNEL_EVENTS.leave, closure({}), timeout);
      leavePush.receive("ok", () => onClose()).receive("timeout", () => onClose());
      leavePush.send();
      if (!this.canPush()) {
        leavePush.trigger("ok", {});
      }
      return leavePush;
    }
    /**
     * Overridable message hook
     *
     * Receives all events for specialized message handling
     * before dispatching to the channel callbacks.
     *
     * Must return the payload, modified or unmodified
     * @param {string} event
     * @param {Object} payload
     * @param {integer} ref
     * @returns {Object}
     */
    onMessage(_event, payload, _ref) {
      return payload;
    }
    /**
     * @private
     */
    isMember(topic, event, payload, joinRef) {
      if (this.topic !== topic) {
        return false;
      }
      if (joinRef && joinRef !== this.joinRef()) {
        if (this.socket.hasLogger()) this.socket.log("channel", "dropping outdated message", { topic, event, payload, joinRef });
        return false;
      } else {
        return true;
      }
    }
    /**
     * @private
     */
    joinRef() {
      return this.joinPush.ref;
    }
    /**
     * @private
     */
    rejoin(timeout = this.timeout) {
      if (this.isLeaving()) {
        return;
      }
      this.socket.leaveOpenTopic(this.topic);
      this.state = CHANNEL_STATES.joining;
      this.joinPush.resend(timeout);
    }
    /**
     * @private
     */
    trigger(event, payload, ref, joinRef) {
      let handledPayload = this.onMessage(event, payload, ref, joinRef);
      if (payload && !handledPayload) {
        throw new Error("channel onMessage callbacks must return the payload, modified or unmodified");
      }
      let eventBindings = this.bindings.filter((bind) => bind.event === event);
      for (let i = 0; i < eventBindings.length; i++) {
        let bind = eventBindings[i];
        bind.callback(handledPayload, ref, joinRef || this.joinRef());
      }
    }
    /**
     * @private
     */
    replyEventName(ref) {
      return `chan_reply_${ref}`;
    }
    /**
     * @private
     */
    isClosed() {
      return this.state === CHANNEL_STATES.closed;
    }
    /**
     * @private
     */
    isErrored() {
      return this.state === CHANNEL_STATES.errored;
    }
    /**
     * @private
     */
    isJoined() {
      return this.state === CHANNEL_STATES.joined;
    }
    /**
     * @private
     */
    isJoining() {
      return this.state === CHANNEL_STATES.joining;
    }
    /**
     * @private
     */
    isLeaving() {
      return this.state === CHANNEL_STATES.leaving;
    }
  };
  var Ajax = class {
    static request(method, endPoint, headers, body, timeout, ontimeout, callback) {
      if (global.XDomainRequest) {
        let req = new global.XDomainRequest();
        return this.xdomainRequest(req, method, endPoint, body, timeout, ontimeout, callback);
      } else if (global.XMLHttpRequest) {
        let req = new global.XMLHttpRequest();
        return this.xhrRequest(req, method, endPoint, headers, body, timeout, ontimeout, callback);
      } else if (global.fetch && global.AbortController) {
        return this.fetchRequest(method, endPoint, headers, body, timeout, ontimeout, callback);
      } else {
        throw new Error("No suitable XMLHttpRequest implementation found");
      }
    }
    static fetchRequest(method, endPoint, headers, body, timeout, ontimeout, callback) {
      let options = {
        method,
        headers,
        body
      };
      let controller = null;
      if (timeout) {
        controller = new AbortController();
        const _timeoutId = setTimeout(() => controller.abort(), timeout);
        options.signal = controller.signal;
      }
      global.fetch(endPoint, options).then((response) => response.text()).then((data) => this.parseJSON(data)).then((data) => callback && callback(data)).catch((err) => {
        if (err.name === "AbortError" && ontimeout) {
          ontimeout();
        } else {
          callback && callback(null);
        }
      });
      return controller;
    }
    static xdomainRequest(req, method, endPoint, body, timeout, ontimeout, callback) {
      req.timeout = timeout;
      req.open(method, endPoint);
      req.onload = () => {
        let response = this.parseJSON(req.responseText);
        callback && callback(response);
      };
      if (ontimeout) {
        req.ontimeout = ontimeout;
      }
      req.onprogress = () => {
      };
      req.send(body);
      return req;
    }
    static xhrRequest(req, method, endPoint, headers, body, timeout, ontimeout, callback) {
      req.open(method, endPoint, true);
      req.timeout = timeout;
      for (let [key, value] of Object.entries(headers)) {
        req.setRequestHeader(key, value);
      }
      req.onerror = () => callback && callback(null);
      req.onreadystatechange = () => {
        if (req.readyState === XHR_STATES.complete && callback) {
          let response = this.parseJSON(req.responseText);
          callback(response);
        }
      };
      if (ontimeout) {
        req.ontimeout = ontimeout;
      }
      req.send(body);
      return req;
    }
    static parseJSON(resp) {
      if (!resp || resp === "") {
        return null;
      }
      try {
        return JSON.parse(resp);
      } catch {
        console && console.log("failed to parse JSON response", resp);
        return null;
      }
    }
    static serialize(obj, parentKey) {
      let queryStr = [];
      for (var key in obj) {
        if (!Object.prototype.hasOwnProperty.call(obj, key)) {
          continue;
        }
        let paramKey = parentKey ? `${parentKey}[${key}]` : key;
        let paramVal = obj[key];
        if (typeof paramVal === "object") {
          queryStr.push(this.serialize(paramVal, paramKey));
        } else {
          queryStr.push(encodeURIComponent(paramKey) + "=" + encodeURIComponent(paramVal));
        }
      }
      return queryStr.join("&");
    }
    static appendParams(url, params) {
      if (Object.keys(params).length === 0) {
        return url;
      }
      let prefix = url.match(/\?/) ? "&" : "?";
      return `${url}${prefix}${this.serialize(params)}`;
    }
  };
  var arrayBufferToBase64 = (buffer) => {
    let binary = "";
    let bytes = new Uint8Array(buffer);
    let len = bytes.byteLength;
    for (let i = 0; i < len; i++) {
      binary += String.fromCharCode(bytes[i]);
    }
    return btoa(binary);
  };
  var LongPoll = class {
    constructor(endPoint, protocols) {
      if (protocols && protocols.length === 2 && protocols[1].startsWith(AUTH_TOKEN_PREFIX)) {
        this.authToken = atob(protocols[1].slice(AUTH_TOKEN_PREFIX.length));
      }
      this.endPoint = null;
      this.token = null;
      this.skipHeartbeat = true;
      this.reqs = /* @__PURE__ */ new Set();
      this.awaitingBatchAck = false;
      this.currentBatch = null;
      this.currentBatchTimer = null;
      this.batchBuffer = [];
      this.onopen = function() {
      };
      this.onerror = function() {
      };
      this.onmessage = function() {
      };
      this.onclose = function() {
      };
      this.pollEndpoint = this.normalizeEndpoint(endPoint);
      this.readyState = SOCKET_STATES.connecting;
      setTimeout(() => this.poll(), 0);
    }
    normalizeEndpoint(endPoint) {
      return endPoint.replace("ws://", "http://").replace("wss://", "https://").replace(new RegExp("(.*)/" + TRANSPORTS.websocket), "$1/" + TRANSPORTS.longpoll);
    }
    endpointURL() {
      return Ajax.appendParams(this.pollEndpoint, { token: this.token });
    }
    closeAndRetry(code, reason, wasClean) {
      this.close(code, reason, wasClean);
      this.readyState = SOCKET_STATES.connecting;
    }
    ontimeout() {
      this.onerror("timeout");
      this.closeAndRetry(1005, "timeout", false);
    }
    isActive() {
      return this.readyState === SOCKET_STATES.open || this.readyState === SOCKET_STATES.connecting;
    }
    poll() {
      const headers = { "Accept": "application/json" };
      if (this.authToken) {
        headers["X-Phoenix-AuthToken"] = this.authToken;
      }
      this.ajax("GET", headers, null, () => this.ontimeout(), (resp) => {
        if (resp) {
          var { status, token, messages } = resp;
          if (status === 410 && this.token !== null) {
            this.onerror(410);
            this.closeAndRetry(3410, "session_gone", false);
            return;
          }
          this.token = token;
        } else {
          status = 0;
        }
        switch (status) {
          case 200:
            messages.forEach((msg) => {
              setTimeout(() => this.onmessage({ data: msg }), 0);
            });
            this.poll();
            break;
          case 204:
            this.poll();
            break;
          case 410:
            this.readyState = SOCKET_STATES.open;
            this.onopen({});
            this.poll();
            break;
          case 403:
            this.onerror(403);
            this.close(1008, "forbidden", false);
            break;
          case 0:
          case 500:
            this.onerror(500);
            this.closeAndRetry(1011, "internal server error", 500);
            break;
          default:
            throw new Error(`unhandled poll status ${status}`);
        }
      });
    }
    // we collect all pushes within the current event loop by
    // setTimeout 0, which optimizes back-to-back procedural
    // pushes against an empty buffer
    send(body) {
      if (typeof body !== "string") {
        body = arrayBufferToBase64(body);
      }
      if (this.currentBatch) {
        this.currentBatch.push(body);
      } else if (this.awaitingBatchAck) {
        this.batchBuffer.push(body);
      } else {
        this.currentBatch = [body];
        this.currentBatchTimer = setTimeout(() => {
          this.batchSend(this.currentBatch);
          this.currentBatch = null;
        }, 0);
      }
    }
    batchSend(messages) {
      this.awaitingBatchAck = true;
      this.ajax("POST", { "Content-Type": "application/x-ndjson" }, messages.join("\n"), () => this.onerror("timeout"), (resp) => {
        this.awaitingBatchAck = false;
        if (!resp || resp.status !== 200) {
          this.onerror(resp && resp.status);
          this.closeAndRetry(1011, "internal server error", false);
        } else if (this.batchBuffer.length > 0) {
          this.batchSend(this.batchBuffer);
          this.batchBuffer = [];
        }
      });
    }
    close(code, reason, wasClean) {
      for (let req of this.reqs) {
        req.abort();
      }
      this.readyState = SOCKET_STATES.closed;
      let opts = Object.assign({ code: 1e3, reason: void 0, wasClean: true }, { code, reason, wasClean });
      this.batchBuffer = [];
      clearTimeout(this.currentBatchTimer);
      this.currentBatchTimer = null;
      if (typeof CloseEvent !== "undefined") {
        this.onclose(new CloseEvent("close", opts));
      } else {
        this.onclose(opts);
      }
    }
    ajax(method, headers, body, onCallerTimeout, callback) {
      let req;
      let ontimeout = () => {
        this.reqs.delete(req);
        onCallerTimeout();
      };
      req = Ajax.request(method, this.endpointURL(), headers, body, this.timeout, ontimeout, (resp) => {
        this.reqs.delete(req);
        if (this.isActive()) {
          callback(resp);
        }
      });
      this.reqs.add(req);
    }
  };
  var serializer_default = {
    HEADER_LENGTH: 1,
    META_LENGTH: 4,
    KINDS: { push: 0, reply: 1, broadcast: 2 },
    encode(msg, callback) {
      if (msg.payload.constructor === ArrayBuffer) {
        return callback(this.binaryEncode(msg));
      } else {
        let payload = [msg.join_ref, msg.ref, msg.topic, msg.event, msg.payload];
        return callback(JSON.stringify(payload));
      }
    },
    decode(rawPayload, callback) {
      if (rawPayload.constructor === ArrayBuffer) {
        return callback(this.binaryDecode(rawPayload));
      } else {
        let [join_ref, ref, topic, event, payload] = JSON.parse(rawPayload);
        return callback({ join_ref, ref, topic, event, payload });
      }
    },
    // private
    binaryEncode(message) {
      let { join_ref, ref, event, topic, payload } = message;
      let metaLength = this.META_LENGTH + join_ref.length + ref.length + topic.length + event.length;
      let header = new ArrayBuffer(this.HEADER_LENGTH + metaLength);
      let view = new DataView(header);
      let offset = 0;
      view.setUint8(offset++, this.KINDS.push);
      view.setUint8(offset++, join_ref.length);
      view.setUint8(offset++, ref.length);
      view.setUint8(offset++, topic.length);
      view.setUint8(offset++, event.length);
      Array.from(join_ref, (char) => view.setUint8(offset++, char.charCodeAt(0)));
      Array.from(ref, (char) => view.setUint8(offset++, char.charCodeAt(0)));
      Array.from(topic, (char) => view.setUint8(offset++, char.charCodeAt(0)));
      Array.from(event, (char) => view.setUint8(offset++, char.charCodeAt(0)));
      var combined = new Uint8Array(header.byteLength + payload.byteLength);
      combined.set(new Uint8Array(header), 0);
      combined.set(new Uint8Array(payload), header.byteLength);
      return combined.buffer;
    },
    binaryDecode(buffer) {
      let view = new DataView(buffer);
      let kind = view.getUint8(0);
      let decoder = new TextDecoder();
      switch (kind) {
        case this.KINDS.push:
          return this.decodePush(buffer, view, decoder);
        case this.KINDS.reply:
          return this.decodeReply(buffer, view, decoder);
        case this.KINDS.broadcast:
          return this.decodeBroadcast(buffer, view, decoder);
      }
    },
    decodePush(buffer, view, decoder) {
      let joinRefSize = view.getUint8(1);
      let topicSize = view.getUint8(2);
      let eventSize = view.getUint8(3);
      let offset = this.HEADER_LENGTH + this.META_LENGTH - 1;
      let joinRef = decoder.decode(buffer.slice(offset, offset + joinRefSize));
      offset = offset + joinRefSize;
      let topic = decoder.decode(buffer.slice(offset, offset + topicSize));
      offset = offset + topicSize;
      let event = decoder.decode(buffer.slice(offset, offset + eventSize));
      offset = offset + eventSize;
      let data = buffer.slice(offset, buffer.byteLength);
      return { join_ref: joinRef, ref: null, topic, event, payload: data };
    },
    decodeReply(buffer, view, decoder) {
      let joinRefSize = view.getUint8(1);
      let refSize = view.getUint8(2);
      let topicSize = view.getUint8(3);
      let eventSize = view.getUint8(4);
      let offset = this.HEADER_LENGTH + this.META_LENGTH;
      let joinRef = decoder.decode(buffer.slice(offset, offset + joinRefSize));
      offset = offset + joinRefSize;
      let ref = decoder.decode(buffer.slice(offset, offset + refSize));
      offset = offset + refSize;
      let topic = decoder.decode(buffer.slice(offset, offset + topicSize));
      offset = offset + topicSize;
      let event = decoder.decode(buffer.slice(offset, offset + eventSize));
      offset = offset + eventSize;
      let data = buffer.slice(offset, buffer.byteLength);
      let payload = { status: event, response: data };
      return { join_ref: joinRef, ref, topic, event: CHANNEL_EVENTS.reply, payload };
    },
    decodeBroadcast(buffer, view, decoder) {
      let topicSize = view.getUint8(1);
      let eventSize = view.getUint8(2);
      let offset = this.HEADER_LENGTH + 2;
      let topic = decoder.decode(buffer.slice(offset, offset + topicSize));
      offset = offset + topicSize;
      let event = decoder.decode(buffer.slice(offset, offset + eventSize));
      offset = offset + eventSize;
      let data = buffer.slice(offset, buffer.byteLength);
      return { join_ref: null, ref: null, topic, event, payload: data };
    }
  };
  var Socket = class {
    constructor(endPoint, opts = {}) {
      this.stateChangeCallbacks = { open: [], close: [], error: [], message: [] };
      this.channels = [];
      this.sendBuffer = [];
      this.ref = 0;
      this.fallbackRef = null;
      this.timeout = opts.timeout || DEFAULT_TIMEOUT;
      this.transport = opts.transport || global.WebSocket || LongPoll;
      this.primaryPassedHealthCheck = false;
      this.longPollFallbackMs = opts.longPollFallbackMs;
      this.fallbackTimer = null;
      this.sessionStore = opts.sessionStorage || global && global.sessionStorage;
      this.establishedConnections = 0;
      this.defaultEncoder = serializer_default.encode.bind(serializer_default);
      this.defaultDecoder = serializer_default.decode.bind(serializer_default);
      this.closeWasClean = false;
      this.disconnecting = false;
      this.binaryType = opts.binaryType || "arraybuffer";
      this.connectClock = 1;
      this.pageHidden = false;
      if (this.transport !== LongPoll) {
        this.encode = opts.encode || this.defaultEncoder;
        this.decode = opts.decode || this.defaultDecoder;
      } else {
        this.encode = this.defaultEncoder;
        this.decode = this.defaultDecoder;
      }
      let awaitingConnectionOnPageShow = null;
      if (phxWindow && phxWindow.addEventListener) {
        phxWindow.addEventListener("pagehide", (_e) => {
          if (this.conn) {
            this.disconnect();
            awaitingConnectionOnPageShow = this.connectClock;
          }
        });
        phxWindow.addEventListener("pageshow", (_e) => {
          if (awaitingConnectionOnPageShow === this.connectClock) {
            awaitingConnectionOnPageShow = null;
            this.connect();
          }
        });
        phxWindow.addEventListener("visibilitychange", () => {
          if (document.visibilityState === "hidden") {
            this.pageHidden = true;
          } else {
            this.pageHidden = false;
            if (!this.isConnected()) {
              this.teardown(() => this.connect());
            }
          }
        });
      }
      this.heartbeatIntervalMs = opts.heartbeatIntervalMs || 3e4;
      this.rejoinAfterMs = (tries) => {
        if (opts.rejoinAfterMs) {
          return opts.rejoinAfterMs(tries);
        } else {
          return [1e3, 2e3, 5e3][tries - 1] || 1e4;
        }
      };
      this.reconnectAfterMs = (tries) => {
        if (opts.reconnectAfterMs) {
          return opts.reconnectAfterMs(tries);
        } else {
          return [10, 50, 100, 150, 200, 250, 500, 1e3, 2e3][tries - 1] || 5e3;
        }
      };
      this.logger = opts.logger || null;
      if (!this.logger && opts.debug) {
        this.logger = (kind, msg, data) => {
          console.log(`${kind}: ${msg}`, data);
        };
      }
      this.longpollerTimeout = opts.longpollerTimeout || 2e4;
      this.params = closure(opts.params || {});
      this.endPoint = `${endPoint}/${TRANSPORTS.websocket}`;
      this.vsn = opts.vsn || DEFAULT_VSN;
      this.heartbeatTimeoutTimer = null;
      this.heartbeatTimer = null;
      this.pendingHeartbeatRef = null;
      this.reconnectTimer = new Timer(() => {
        if (this.pageHidden) {
          this.log("Not reconnecting as page is hidden!");
          this.teardown();
          return;
        }
        this.teardown(() => this.connect());
      }, this.reconnectAfterMs);
      this.authToken = opts.authToken;
    }
    /**
     * Returns the LongPoll transport reference
     */
    getLongPollTransport() {
      return LongPoll;
    }
    /**
     * Disconnects and replaces the active transport
     *
     * @param {Function} newTransport - The new transport class to instantiate
     *
     */
    replaceTransport(newTransport) {
      this.connectClock++;
      this.closeWasClean = true;
      clearTimeout(this.fallbackTimer);
      this.reconnectTimer.reset();
      if (this.conn) {
        this.conn.close();
        this.conn = null;
      }
      this.transport = newTransport;
    }
    /**
     * Returns the socket protocol
     *
     * @returns {string}
     */
    protocol() {
      return location.protocol.match(/^https/) ? "wss" : "ws";
    }
    /**
     * The fully qualified socket url
     *
     * @returns {string}
     */
    endPointURL() {
      let uri = Ajax.appendParams(
        Ajax.appendParams(this.endPoint, this.params()),
        { vsn: this.vsn }
      );
      if (uri.charAt(0) !== "/") {
        return uri;
      }
      if (uri.charAt(1) === "/") {
        return `${this.protocol()}:${uri}`;
      }
      return `${this.protocol()}://${location.host}${uri}`;
    }
    /**
     * Disconnects the socket
     *
     * See https://developer.mozilla.org/en-US/docs/Web/API/CloseEvent#Status_codes for valid status codes.
     *
     * @param {Function} callback - Optional callback which is called after socket is disconnected.
     * @param {integer} code - A status code for disconnection (Optional).
     * @param {string} reason - A textual description of the reason to disconnect. (Optional)
     */
    disconnect(callback, code, reason) {
      this.connectClock++;
      this.disconnecting = true;
      this.closeWasClean = true;
      clearTimeout(this.fallbackTimer);
      this.reconnectTimer.reset();
      this.teardown(() => {
        this.disconnecting = false;
        callback && callback();
      }, code, reason);
    }
    /**
     *
     * @param {Object} params - The params to send when connecting, for example `{user_id: userToken}`
     *
     * Passing params to connect is deprecated; pass them in the Socket constructor instead:
     * `new Socket("/socket", {params: {user_id: userToken}})`.
     */
    connect(params) {
      if (params) {
        console && console.log("passing params to connect is deprecated. Instead pass :params to the Socket constructor");
        this.params = closure(params);
      }
      if (this.conn && !this.disconnecting) {
        return;
      }
      if (this.longPollFallbackMs && this.transport !== LongPoll) {
        this.connectWithFallback(LongPoll, this.longPollFallbackMs);
      } else {
        this.transportConnect();
      }
    }
    /**
     * Logs the message. Override `this.logger` for specialized logging. noops by default
     * @param {string} kind
     * @param {string} msg
     * @param {Object} data
     */
    log(kind, msg, data) {
      this.logger && this.logger(kind, msg, data);
    }
    /**
     * Returns true if a logger has been set on this socket.
     */
    hasLogger() {
      return this.logger !== null;
    }
    /**
     * Registers callbacks for connection open events
     *
     * @example socket.onOpen(function(){ console.info("the socket was opened") })
     *
     * @param {Function} callback
     */
    onOpen(callback) {
      let ref = this.makeRef();
      this.stateChangeCallbacks.open.push([ref, callback]);
      return ref;
    }
    /**
     * Registers callbacks for connection close events
     * @param {Function} callback
     */
    onClose(callback) {
      let ref = this.makeRef();
      this.stateChangeCallbacks.close.push([ref, callback]);
      return ref;
    }
    /**
     * Registers callbacks for connection error events
     *
     * @example socket.onError(function(error){ alert("An error occurred") })
     *
     * @param {Function} callback
     */
    onError(callback) {
      let ref = this.makeRef();
      this.stateChangeCallbacks.error.push([ref, callback]);
      return ref;
    }
    /**
     * Registers callbacks for connection message events
     * @param {Function} callback
     */
    onMessage(callback) {
      let ref = this.makeRef();
      this.stateChangeCallbacks.message.push([ref, callback]);
      return ref;
    }
    /**
     * Pings the server and invokes the callback with the RTT in milliseconds
     * @param {Function} callback
     *
     * Returns true if the ping was pushed or false if unable to be pushed.
     */
    ping(callback) {
      if (!this.isConnected()) {
        return false;
      }
      let ref = this.makeRef();
      let startTime = Date.now();
      this.push({ topic: "phoenix", event: "heartbeat", payload: {}, ref });
      let onMsgRef = this.onMessage((msg) => {
        if (msg.ref === ref) {
          this.off([onMsgRef]);
          callback(Date.now() - startTime);
        }
      });
      return true;
    }
    /**
     * @private
     */
    transportConnect() {
      this.connectClock++;
      this.closeWasClean = false;
      let protocols = void 0;
      if (this.authToken) {
        protocols = ["phoenix", `${AUTH_TOKEN_PREFIX}${btoa(this.authToken).replace(/=/g, "")}`];
      }
      this.conn = new this.transport(this.endPointURL(), protocols);
      this.conn.binaryType = this.binaryType;
      this.conn.timeout = this.longpollerTimeout;
      this.conn.onopen = () => this.onConnOpen();
      this.conn.onerror = (error) => this.onConnError(error);
      this.conn.onmessage = (event) => this.onConnMessage(event);
      this.conn.onclose = (event) => this.onConnClose(event);
    }
    getSession(key) {
      return this.sessionStore && this.sessionStore.getItem(key);
    }
    storeSession(key, val) {
      this.sessionStore && this.sessionStore.setItem(key, val);
    }
    connectWithFallback(fallbackTransport, fallbackThreshold = 2500) {
      clearTimeout(this.fallbackTimer);
      let established = false;
      let primaryTransport = true;
      let openRef, errorRef;
      let fallback = (reason) => {
        this.log("transport", `falling back to ${fallbackTransport.name}...`, reason);
        this.off([openRef, errorRef]);
        primaryTransport = false;
        this.replaceTransport(fallbackTransport);
        this.transportConnect();
      };
      if (this.getSession(`phx:fallback:${fallbackTransport.name}`)) {
        return fallback("memorized");
      }
      this.fallbackTimer = setTimeout(fallback, fallbackThreshold);
      errorRef = this.onError((reason) => {
        this.log("transport", "error", reason);
        if (primaryTransport && !established) {
          clearTimeout(this.fallbackTimer);
          fallback(reason);
        }
      });
      if (this.fallbackRef) {
        this.off([this.fallbackRef]);
      }
      this.fallbackRef = this.onOpen(() => {
        established = true;
        if (!primaryTransport) {
          if (!this.primaryPassedHealthCheck) {
            this.storeSession(`phx:fallback:${fallbackTransport.name}`, "true");
          }
          return this.log("transport", `established ${fallbackTransport.name} fallback`);
        }
        clearTimeout(this.fallbackTimer);
        this.fallbackTimer = setTimeout(fallback, fallbackThreshold);
        this.ping((rtt) => {
          this.log("transport", "connected to primary after", rtt);
          this.primaryPassedHealthCheck = true;
          clearTimeout(this.fallbackTimer);
        });
      });
      this.transportConnect();
    }
    clearHeartbeats() {
      clearTimeout(this.heartbeatTimer);
      clearTimeout(this.heartbeatTimeoutTimer);
    }
    onConnOpen() {
      if (this.hasLogger()) this.log("transport", `${this.transport.name} connected to ${this.endPointURL()}`);
      this.closeWasClean = false;
      this.disconnecting = false;
      this.establishedConnections++;
      this.flushSendBuffer();
      this.reconnectTimer.reset();
      this.resetHeartbeat();
      this.stateChangeCallbacks.open.forEach(([, callback]) => callback());
    }
    /**
     * @private
     */
    heartbeatTimeout() {
      if (this.pendingHeartbeatRef) {
        this.pendingHeartbeatRef = null;
        if (this.hasLogger()) {
          this.log("transport", "heartbeat timeout. Attempting to re-establish connection");
        }
        this.triggerChanError();
        this.closeWasClean = false;
        this.teardown(() => this.reconnectTimer.scheduleTimeout(), WS_CLOSE_NORMAL, "heartbeat timeout");
      }
    }
    resetHeartbeat() {
      if (this.conn && this.conn.skipHeartbeat) {
        return;
      }
      this.pendingHeartbeatRef = null;
      this.clearHeartbeats();
      this.heartbeatTimer = setTimeout(() => this.sendHeartbeat(), this.heartbeatIntervalMs);
    }
    teardown(callback, code, reason) {
      if (!this.conn) {
        return callback && callback();
      }
      let connectClock = this.connectClock;
      this.waitForBufferDone(() => {
        if (connectClock !== this.connectClock) {
          return;
        }
        if (this.conn) {
          if (code) {
            this.conn.close(code, reason || "");
          } else {
            this.conn.close();
          }
        }
        this.waitForSocketClosed(() => {
          if (connectClock !== this.connectClock) {
            return;
          }
          if (this.conn) {
            this.conn.onopen = function() {
            };
            this.conn.onerror = function() {
            };
            this.conn.onmessage = function() {
            };
            this.conn.onclose = function() {
            };
            this.conn = null;
          }
          callback && callback();
        });
      });
    }
    waitForBufferDone(callback, tries = 1) {
      if (tries === 5 || !this.conn || !this.conn.bufferedAmount) {
        callback();
        return;
      }
      setTimeout(() => {
        this.waitForBufferDone(callback, tries + 1);
      }, 150 * tries);
    }
    waitForSocketClosed(callback, tries = 1) {
      if (tries === 5 || !this.conn || this.conn.readyState === SOCKET_STATES.closed) {
        callback();
        return;
      }
      setTimeout(() => {
        this.waitForSocketClosed(callback, tries + 1);
      }, 150 * tries);
    }
    onConnClose(event) {
      if (this.conn) this.conn.onclose = () => {
      };
      let closeCode = event && event.code;
      if (this.hasLogger()) this.log("transport", "close", event);
      this.triggerChanError();
      this.clearHeartbeats();
      if (!this.closeWasClean && closeCode !== 1e3) {
        this.reconnectTimer.scheduleTimeout();
      }
      this.stateChangeCallbacks.close.forEach(([, callback]) => callback(event));
    }
    /**
     * @private
     */
    onConnError(error) {
      if (this.hasLogger()) this.log("transport", error);
      let transportBefore = this.transport;
      let establishedBefore = this.establishedConnections;
      this.stateChangeCallbacks.error.forEach(([, callback]) => {
        callback(error, transportBefore, establishedBefore);
      });
      if (transportBefore === this.transport || establishedBefore > 0) {
        this.triggerChanError();
      }
    }
    /**
     * @private
     */
    triggerChanError() {
      this.channels.forEach((channel) => {
        if (!(channel.isErrored() || channel.isLeaving() || channel.isClosed())) {
          channel.trigger(CHANNEL_EVENTS.error);
        }
      });
    }
    /**
     * @returns {string}
     */
    connectionState() {
      switch (this.conn && this.conn.readyState) {
        case SOCKET_STATES.connecting:
          return "connecting";
        case SOCKET_STATES.open:
          return "open";
        case SOCKET_STATES.closing:
          return "closing";
        default:
          return "closed";
      }
    }
    /**
     * @returns {boolean}
     */
    isConnected() {
      return this.connectionState() === "open";
    }
    /**
     * @private
     *
     * @param {Channel}
     */
    remove(channel) {
      this.off(channel.stateChangeRefs);
      this.channels = this.channels.filter((c) => c !== channel);
    }
    /**
     * Removes `onOpen`, `onClose`, `onError,` and `onMessage` registrations.
     *
     * @param {refs} - list of refs returned by calls to
     *                 `onOpen`, `onClose`, `onError,` and `onMessage`
     */
    off(refs) {
      for (let key in this.stateChangeCallbacks) {
        this.stateChangeCallbacks[key] = this.stateChangeCallbacks[key].filter(([ref]) => {
          return refs.indexOf(ref) === -1;
        });
      }
    }
    /**
     * Initiates a new channel for the given topic
     *
     * @param {string} topic
     * @param {Object} chanParams - Parameters for the channel
     * @returns {Channel}
     */
    channel(topic, chanParams = {}) {
      let chan = new Channel(topic, chanParams, this);
      this.channels.push(chan);
      return chan;
    }
    /**
     * @param {Object} data
     */
    push(data) {
      if (this.hasLogger()) {
        let { topic, event, payload, ref, join_ref } = data;
        this.log("push", `${topic} ${event} (${join_ref}, ${ref})`, payload);
      }
      if (this.isConnected()) {
        this.encode(data, (result) => this.conn.send(result));
      } else {
        this.sendBuffer.push(() => this.encode(data, (result) => this.conn.send(result)));
      }
    }
    /**
     * Return the next message ref, accounting for overflows
     * @returns {string}
     */
    makeRef() {
      let newRef = this.ref + 1;
      if (newRef === this.ref) {
        this.ref = 0;
      } else {
        this.ref = newRef;
      }
      return this.ref.toString();
    }
    sendHeartbeat() {
      if (this.pendingHeartbeatRef && !this.isConnected()) {
        return;
      }
      this.pendingHeartbeatRef = this.makeRef();
      this.push({ topic: "phoenix", event: "heartbeat", payload: {}, ref: this.pendingHeartbeatRef });
      this.heartbeatTimeoutTimer = setTimeout(() => this.heartbeatTimeout(), this.heartbeatIntervalMs);
    }
    flushSendBuffer() {
      if (this.isConnected() && this.sendBuffer.length > 0) {
        this.sendBuffer.forEach((callback) => callback());
        this.sendBuffer = [];
      }
    }
    onConnMessage(rawMessage) {
      this.decode(rawMessage.data, (msg) => {
        let { topic, event, payload, ref, join_ref } = msg;
        if (ref && ref === this.pendingHeartbeatRef) {
          this.clearHeartbeats();
          this.pendingHeartbeatRef = null;
          this.heartbeatTimer = setTimeout(() => this.sendHeartbeat(), this.heartbeatIntervalMs);
        }
        if (this.hasLogger()) this.log("receive", `${payload.status || ""} ${topic} ${event} ${ref && "(" + ref + ")" || ""}`, payload);
        for (let i = 0; i < this.channels.length; i++) {
          const channel = this.channels[i];
          if (!channel.isMember(topic, event, payload, join_ref)) {
            continue;
          }
          channel.trigger(event, payload, ref, join_ref);
        }
        for (let i = 0; i < this.stateChangeCallbacks.message.length; i++) {
          let [, callback] = this.stateChangeCallbacks.message[i];
          callback(msg);
        }
      });
    }
    leaveOpenTopic(topic) {
      let dupChannel = this.channels.find((c) => c.topic === topic && (c.isJoined() || c.isJoining()));
      if (dupChannel) {
        if (this.hasLogger()) this.log("transport", `leaving duplicate topic "${topic}"`);
        dupChannel.leave();
      }
    }
  };

  // ../deps/phoenix_live_view/priv/static/phoenix_live_view.esm.js
  var CONSECUTIVE_RELOADS = "consecutive-reloads";
  var MAX_RELOADS = 10;
  var RELOAD_JITTER_MIN = 5e3;
  var RELOAD_JITTER_MAX = 1e4;
  var FAILSAFE_JITTER = 3e4;
  var PHX_EVENT_CLASSES = [
    "phx-click-loading",
    "phx-change-loading",
    "phx-submit-loading",
    "phx-keydown-loading",
    "phx-keyup-loading",
    "phx-blur-loading",
    "phx-focus-loading",
    "phx-hook-loading"
  ];
  var PHX_DROP_TARGET_ACTIVE_CLASS = "phx-drop-target-active";
  var PHX_COMPONENT = "data-phx-component";
  var PHX_VIEW_REF = "data-phx-view";
  var PHX_LIVE_LINK = "data-phx-link";
  var PHX_TRACK_STATIC = "track-static";
  var PHX_LINK_STATE = "data-phx-link-state";
  var PHX_REF_LOADING = "data-phx-ref-loading";
  var PHX_REF_SRC = "data-phx-ref-src";
  var PHX_REF_LOCK = "data-phx-ref-lock";
  var PHX_PENDING_REFS = "phx-pending-refs";
  var PHX_TRACK_UPLOADS = "track-uploads";
  var PHX_UPLOAD_REF = "data-phx-upload-ref";
  var PHX_PREFLIGHTED_REFS = "data-phx-preflighted-refs";
  var PHX_DONE_REFS = "data-phx-done-refs";
  var PHX_DROP_TARGET = "drop-target";
  var PHX_ACTIVE_ENTRY_REFS = "data-phx-active-refs";
  var PHX_LIVE_FILE_UPDATED = "phx:live-file:updated";
  var PHX_SKIP = "data-phx-skip";
  var PHX_MAGIC_ID = "data-phx-id";
  var PHX_PRUNE = "data-phx-prune";
  var PHX_CONNECTED_CLASS = "phx-connected";
  var PHX_LOADING_CLASS = "phx-loading";
  var PHX_ERROR_CLASS = "phx-error";
  var PHX_CLIENT_ERROR_CLASS = "phx-client-error";
  var PHX_SERVER_ERROR_CLASS = "phx-server-error";
  var PHX_PARENT_ID = "data-phx-parent-id";
  var PHX_MAIN = "data-phx-main";
  var PHX_ROOT_ID = "data-phx-root-id";
  var PHX_VIEWPORT_TOP = "viewport-top";
  var PHX_VIEWPORT_BOTTOM = "viewport-bottom";
  var PHX_VIEWPORT_OVERRUN_TARGET = "viewport-overrun-target";
  var PHX_TRIGGER_ACTION = "trigger-action";
  var PHX_HAS_FOCUSED = "phx-has-focused";
  var FOCUSABLE_INPUTS = [
    "text",
    "textarea",
    "number",
    "email",
    "password",
    "search",
    "tel",
    "url",
    "date",
    "time",
    "datetime-local",
    "color",
    "range"
  ];
  var CHECKABLE_INPUTS = ["checkbox", "radio"];
  var PHX_HAS_SUBMITTED = "phx-has-submitted";
  var PHX_SESSION = "data-phx-session";
  var PHX_VIEW_SELECTOR = `[${PHX_SESSION}]`;
  var PHX_STICKY = "data-phx-sticky";
  var PHX_STATIC = "data-phx-static";
  var PHX_READONLY = "data-phx-readonly";
  var PHX_DISABLED = "data-phx-disabled";
  var PHX_DISABLE_WITH = "disable-with";
  var PHX_DISABLE_WITH_RESTORE = "data-phx-disable-with-restore";
  var PHX_HOOK = "hook";
  var PHX_DEBOUNCE = "debounce";
  var PHX_THROTTLE = "throttle";
  var PHX_UPDATE = "update";
  var PHX_STREAM = "stream";
  var PHX_STREAM_REF = "data-phx-stream";
  var PHX_PORTAL = "data-phx-portal";
  var PHX_TELEPORTED_REF = "data-phx-teleported";
  var PHX_TELEPORTED_SRC = "data-phx-teleported-src";
  var PHX_RUNTIME_HOOK = "data-phx-runtime-hook";
  var PHX_LV_PID = "data-phx-pid";
  var PHX_KEY = "key";
  var PHX_PRIVATE = "phxPrivate";
  var PHX_AUTO_RECOVER = "auto-recover";
  var PHX_LV_DEBUG = "phx:live-socket:debug";
  var PHX_LV_PROFILE = "phx:live-socket:profiling";
  var PHX_LV_LATENCY_SIM = "phx:live-socket:latency-sim";
  var PHX_LV_HISTORY_POSITION = "phx:nav-history-position";
  var PHX_PROGRESS = "progress";
  var PHX_MOUNTED = "mounted";
  var PHX_RELOAD_STATUS = "__phoenix_reload_status__";
  var LOADER_TIMEOUT = 1;
  var MAX_CHILD_JOIN_ATTEMPTS = 3;
  var BEFORE_UNLOAD_LOADER_TIMEOUT = 200;
  var DISCONNECTED_TIMEOUT = 500;
  var BINDING_PREFIX = "phx-";
  var PUSH_TIMEOUT = 3e4;
  var DEBOUNCE_TRIGGER = "debounce-trigger";
  var THROTTLED = "throttled";
  var DEBOUNCE_PREV_KEY = "debounce-prev-key";
  var DEFAULTS = {
    debounce: 300,
    throttle: 300
  };
  var PHX_PENDING_ATTRS = [PHX_REF_LOADING, PHX_REF_SRC, PHX_REF_LOCK];
  var STATIC = "s";
  var ROOT = "r";
  var COMPONENTS = "c";
  var KEYED = "k";
  var KEYED_COUNT = "kc";
  var EVENTS = "e";
  var REPLY = "r";
  var TITLE = "t";
  var TEMPLATES = "p";
  var STREAM = "stream";
  var EntryUploader = class {
    constructor(entry, config, liveSocket2) {
      const { chunk_size, chunk_timeout } = config;
      this.liveSocket = liveSocket2;
      this.entry = entry;
      this.offset = 0;
      this.chunkSize = chunk_size;
      this.chunkTimeout = chunk_timeout;
      this.chunkTimer = null;
      this.errored = false;
      this.uploadChannel = liveSocket2.channel(`lvu:${entry.ref}`, {
        token: entry.metadata()
      });
    }
    error(reason) {
      if (this.errored) {
        return;
      }
      this.uploadChannel.leave();
      this.errored = true;
      clearTimeout(this.chunkTimer);
      this.entry.error(reason);
    }
    upload() {
      this.uploadChannel.onError((reason) => this.error(reason));
      this.uploadChannel.join().receive("ok", (_data) => this.readNextChunk()).receive("error", (reason) => this.error(reason));
    }
    isDone() {
      return this.offset >= this.entry.file.size;
    }
    readNextChunk() {
      const reader = new window.FileReader();
      const blob = this.entry.file.slice(
        this.offset,
        this.chunkSize + this.offset
      );
      reader.onload = (e) => {
        if (e.target.error === null) {
          this.offset += /** @type {ArrayBuffer} */
          e.target.result.byteLength;
          this.pushChunk(
            /** @type {ArrayBuffer} */
            e.target.result
          );
        } else {
          return logError("Read error: " + e.target.error);
        }
      };
      reader.readAsArrayBuffer(blob);
    }
    pushChunk(chunk) {
      if (!this.uploadChannel.isJoined()) {
        return;
      }
      this.uploadChannel.push("chunk", chunk, this.chunkTimeout).receive("ok", () => {
        this.entry.progress(this.offset / this.entry.file.size * 100);
        if (!this.isDone()) {
          this.chunkTimer = setTimeout(
            () => this.readNextChunk(),
            this.liveSocket.getLatencySim() || 0
          );
        }
      }).receive("error", ({ reason }) => this.error(reason));
    }
  };
  var logError = (msg, obj) => console.error && console.error(msg, obj);
  var isCid = (cid) => {
    const type = typeof cid;
    return type === "number" || type === "string" && /^(0|[1-9]\d*)$/.test(cid);
  };
  function detectDuplicateIds() {
    const ids = /* @__PURE__ */ new Set();
    const elems = document.querySelectorAll("*[id]");
    for (let i = 0, len = elems.length; i < len; i++) {
      if (ids.has(elems[i].id)) {
        console.error(
          `Multiple IDs detected: ${elems[i].id}. Ensure unique element ids.`
        );
      } else {
        ids.add(elems[i].id);
      }
    }
  }
  function detectInvalidStreamInserts(inserts) {
    const errors = /* @__PURE__ */ new Set();
    Object.keys(inserts).forEach((id) => {
      const streamEl = document.getElementById(id);
      if (streamEl && streamEl.parentElement && streamEl.parentElement.getAttribute("phx-update") !== "stream") {
        errors.add(
          `The stream container with id "${streamEl.parentElement.id}" is missing the phx-update="stream" attribute. Ensure it is set for streams to work properly.`
        );
      }
    });
    errors.forEach((error) => console.error(error));
  }
  var debug = (view, kind, msg, obj) => {
    if (view.liveSocket.isDebugEnabled()) {
      console.log(`${view.id} ${kind}: ${msg} - `, obj);
    }
  };
  var closure2 = (val) => typeof val === "function" ? val : function() {
    return val;
  };
  var clone = (obj) => {
    return JSON.parse(JSON.stringify(obj));
  };
  var closestPhxBinding = (el, binding, borderEl) => {
    do {
      if (el.matches(`[${binding}]`) && !el.disabled) {
        return el;
      }
      el = el.parentElement || el.parentNode;
    } while (el !== null && el.nodeType === 1 && !(borderEl && borderEl.isSameNode(el) || el.matches(PHX_VIEW_SELECTOR)));
    return null;
  };
  var isObject = (obj) => {
    return obj !== null && typeof obj === "object" && !(obj instanceof Array);
  };
  var isEqualObj = (obj1, obj2) => JSON.stringify(obj1) === JSON.stringify(obj2);
  var isEmpty = (obj) => {
    for (const x in obj) {
      return false;
    }
    return true;
  };
  var maybe = (el, callback) => el && callback(el);
  var channelUploader = function(entries, onError, resp, liveSocket2) {
    entries.forEach((entry) => {
      const entryUploader = new EntryUploader(entry, resp.config, liveSocket2);
      entryUploader.upload();
    });
  };
  var eventContainsFiles = (e) => {
    if (e.dataTransfer.types) {
      for (let i = 0; i < e.dataTransfer.types.length; i++) {
        if (e.dataTransfer.types[i] === "Files") {
          return true;
        }
      }
    }
    return false;
  };
  var Browser = {
    canPushState() {
      return typeof history.pushState !== "undefined";
    },
    dropLocal(localStorage, namespace, subkey) {
      return localStorage.removeItem(this.localKey(namespace, subkey));
    },
    updateLocal(localStorage, namespace, subkey, initial, func) {
      const current = this.getLocal(localStorage, namespace, subkey);
      const key = this.localKey(namespace, subkey);
      const newVal = current === null ? initial : func(current);
      localStorage.setItem(key, JSON.stringify(newVal));
      return newVal;
    },
    getLocal(localStorage, namespace, subkey) {
      return JSON.parse(localStorage.getItem(this.localKey(namespace, subkey)));
    },
    updateCurrentState(callback) {
      if (!this.canPushState()) {
        return;
      }
      history.replaceState(
        callback(history.state || {}),
        "",
        window.location.href
      );
    },
    pushState(kind, meta, to) {
      if (this.canPushState()) {
        if (to !== window.location.href) {
          if (meta.type == "redirect" && meta.scroll) {
            const currentState = history.state || {};
            currentState.scroll = meta.scroll;
            history.replaceState(currentState, "", window.location.href);
          }
          delete meta.scroll;
          history[kind + "State"](meta, "", to || null);
          window.requestAnimationFrame(() => {
            const hashEl = this.getHashTargetEl(window.location.hash);
            if (hashEl) {
              hashEl.scrollIntoView();
            } else if (meta.type === "redirect") {
              window.scroll(0, 0);
            }
          });
        }
      } else {
        this.redirect(to);
      }
    },
    setCookie(name, value, maxAgeSeconds) {
      const expires = typeof maxAgeSeconds === "number" ? ` max-age=${maxAgeSeconds};` : "";
      document.cookie = `${name}=${value};${expires} path=/`;
    },
    getCookie(name) {
      return document.cookie.replace(
        new RegExp(`(?:(?:^|.*;s*)${name}s*=s*([^;]*).*$)|^.*$`),
        "$1"
      );
    },
    deleteCookie(name) {
      document.cookie = `${name}=; max-age=-1; path=/`;
    },
    redirect(toURL, flash, navigate = (url) => {
      window.location.href = url;
    }) {
      if (flash) {
        this.setCookie("__phoenix_flash__", flash, 60);
      }
      navigate(toURL);
    },
    localKey(namespace, subkey) {
      return `${namespace}-${subkey}`;
    },
    getHashTargetEl(maybeHash) {
      const hash = maybeHash.toString().substring(1);
      if (hash === "") {
        return;
      }
      return document.getElementById(hash) || document.querySelector(`a[name="${hash}"]`);
    }
  };
  var browser_default = Browser;
  var DOM = {
    byId(id) {
      return document.getElementById(id) || logError(`no id found for ${id}`);
    },
    removeClass(el, className) {
      el.classList.remove(className);
      if (el.classList.length === 0) {
        el.removeAttribute("class");
      }
    },
    all(node, query, callback) {
      if (!node) {
        return [];
      }
      const array = Array.from(node.querySelectorAll(query));
      if (callback) {
        array.forEach(callback);
      }
      return array;
    },
    childNodeLength(html) {
      const template = document.createElement("template");
      template.innerHTML = html;
      return template.content.childElementCount;
    },
    isUploadInput(el) {
      return el.type === "file" && el.getAttribute(PHX_UPLOAD_REF) !== null;
    },
    isAutoUpload(inputEl) {
      return inputEl.hasAttribute("data-phx-auto-upload");
    },
    findUploadInputs(node) {
      const formId = node.id;
      const inputsOutsideForm = this.all(
        document,
        `input[type="file"][${PHX_UPLOAD_REF}][form="${formId}"]`
      );
      return this.all(node, `input[type="file"][${PHX_UPLOAD_REF}]`).concat(
        inputsOutsideForm
      );
    },
    findComponentNodeList(viewId, cid, doc2 = document) {
      return this.all(
        doc2,
        `[${PHX_VIEW_REF}="${viewId}"][${PHX_COMPONENT}="${cid}"]`
      );
    },
    isPhxDestroyed(node) {
      return node.id && DOM.private(node, "destroyed") ? true : false;
    },
    wantsNewTab(e) {
      const wantsNewTab = e.ctrlKey || e.shiftKey || e.metaKey || e.button && e.button === 1;
      const isDownload = e.target instanceof HTMLAnchorElement && e.target.hasAttribute("download");
      const isTargetBlank = e.target.hasAttribute("target") && e.target.getAttribute("target").toLowerCase() === "_blank";
      const isTargetNamedTab = e.target.hasAttribute("target") && !e.target.getAttribute("target").startsWith("_");
      return wantsNewTab || isTargetBlank || isDownload || isTargetNamedTab;
    },
    isUnloadableFormSubmit(e) {
      const isDialogSubmit = e.target && e.target.getAttribute("method") === "dialog" || e.submitter && e.submitter.getAttribute("formmethod") === "dialog";
      if (isDialogSubmit) {
        return false;
      } else {
        return !e.defaultPrevented && !this.wantsNewTab(e);
      }
    },
    isNewPageClick(e, currentLocation) {
      const href = e.target instanceof HTMLAnchorElement ? e.target.getAttribute("href") : null;
      let url;
      if (e.defaultPrevented || href === null || this.wantsNewTab(e)) {
        return false;
      }
      if (href.startsWith("mailto:") || href.startsWith("tel:")) {
        return false;
      }
      if (e.target.isContentEditable) {
        return false;
      }
      try {
        url = new URL(href);
      } catch {
        try {
          url = new URL(href, currentLocation);
        } catch {
          return true;
        }
      }
      if (url.host === currentLocation.host && url.protocol === currentLocation.protocol) {
        if (url.pathname === currentLocation.pathname && url.search === currentLocation.search) {
          return url.hash === "" && !url.href.endsWith("#");
        }
      }
      return url.protocol.startsWith("http");
    },
    markPhxChildDestroyed(el) {
      if (this.isPhxChild(el)) {
        el.setAttribute(PHX_SESSION, "");
      }
      this.putPrivate(el, "destroyed", true);
    },
    findPhxChildrenInFragment(html, parentId) {
      const template = document.createElement("template");
      template.innerHTML = html;
      return this.findPhxChildren(template.content, parentId);
    },
    isIgnored(el, phxUpdate) {
      return (el.getAttribute(phxUpdate) || el.getAttribute("data-phx-update")) === "ignore";
    },
    isPhxUpdate(el, phxUpdate, updateTypes) {
      return el.getAttribute && updateTypes.indexOf(el.getAttribute(phxUpdate)) >= 0;
    },
    findPhxSticky(el) {
      return this.all(el, `[${PHX_STICKY}]`);
    },
    findPhxChildren(el, parentId) {
      return this.all(el, `${PHX_VIEW_SELECTOR}[${PHX_PARENT_ID}="${parentId}"]`);
    },
    findExistingParentCIDs(viewId, cids) {
      const parentCids = /* @__PURE__ */ new Set();
      const childrenCids = /* @__PURE__ */ new Set();
      cids.forEach((cid) => {
        this.all(
          document,
          `[${PHX_VIEW_REF}="${viewId}"][${PHX_COMPONENT}="${cid}"]`
        ).forEach((parent) => {
          parentCids.add(cid);
          this.all(parent, `[${PHX_VIEW_REF}="${viewId}"][${PHX_COMPONENT}]`).map((el) => parseInt(el.getAttribute(PHX_COMPONENT))).forEach((childCID) => childrenCids.add(childCID));
        });
      });
      childrenCids.forEach((childCid) => parentCids.delete(childCid));
      return parentCids;
    },
    private(el, key) {
      return el[PHX_PRIVATE] && el[PHX_PRIVATE][key];
    },
    deletePrivate(el, key) {
      el[PHX_PRIVATE] && delete el[PHX_PRIVATE][key];
    },
    putPrivate(el, key, value) {
      if (!el[PHX_PRIVATE]) {
        el[PHX_PRIVATE] = {};
      }
      el[PHX_PRIVATE][key] = value;
    },
    updatePrivate(el, key, defaultVal, updateFunc) {
      const existing = this.private(el, key);
      if (existing === void 0) {
        this.putPrivate(el, key, updateFunc(defaultVal));
      } else {
        this.putPrivate(el, key, updateFunc(existing));
      }
    },
    syncPendingAttrs(fromEl, toEl) {
      if (!fromEl.hasAttribute(PHX_REF_SRC)) {
        return;
      }
      PHX_EVENT_CLASSES.forEach((className) => {
        fromEl.classList.contains(className) && toEl.classList.add(className);
      });
      PHX_PENDING_ATTRS.filter((attr) => fromEl.hasAttribute(attr)).forEach(
        (attr) => {
          toEl.setAttribute(attr, fromEl.getAttribute(attr));
        }
      );
    },
    copyPrivates(target, source) {
      if (source[PHX_PRIVATE]) {
        target[PHX_PRIVATE] = source[PHX_PRIVATE];
      }
    },
    putTitle(str) {
      const titleEl = document.querySelector("title");
      if (titleEl) {
        const { prefix, suffix, default: defaultTitle } = titleEl.dataset;
        const isEmpty2 = typeof str !== "string" || str.trim() === "";
        if (isEmpty2 && typeof defaultTitle !== "string") {
          return;
        }
        const inner = isEmpty2 ? defaultTitle : str;
        document.title = `${prefix || ""}${inner || ""}${suffix || ""}`;
      } else {
        document.title = str;
      }
    },
    debounce(el, event, phxDebounce, defaultDebounce, phxThrottle, defaultThrottle, asyncFilter, callback) {
      let debounce = el.getAttribute(phxDebounce);
      let throttle = el.getAttribute(phxThrottle);
      if (debounce === "") {
        debounce = defaultDebounce;
      }
      if (throttle === "") {
        throttle = defaultThrottle;
      }
      const value = debounce || throttle;
      switch (value) {
        case null:
          return callback();
        case "blur":
          this.incCycle(el, "debounce-blur-cycle", () => {
            if (asyncFilter()) {
              callback();
            }
          });
          if (this.once(el, "debounce-blur")) {
            el.addEventListener(
              "blur",
              () => this.triggerCycle(el, "debounce-blur-cycle")
            );
          }
          return;
        default:
          const timeout = parseInt(value);
          const trigger = () => throttle ? this.deletePrivate(el, THROTTLED) : callback();
          const currentCycle = this.incCycle(el, DEBOUNCE_TRIGGER, trigger);
          if (isNaN(timeout)) {
            return logError(`invalid throttle/debounce value: ${value}`);
          }
          if (throttle) {
            let newKeyDown = false;
            if (event.type === "keydown") {
              const prevKey = this.private(el, DEBOUNCE_PREV_KEY);
              this.putPrivate(el, DEBOUNCE_PREV_KEY, event.key);
              newKeyDown = prevKey !== event.key;
            }
            if (!newKeyDown && this.private(el, THROTTLED)) {
              return false;
            } else {
              callback();
              const t = setTimeout(() => {
                if (asyncFilter()) {
                  this.triggerCycle(el, DEBOUNCE_TRIGGER);
                }
              }, timeout);
              this.putPrivate(el, THROTTLED, t);
            }
          } else {
            setTimeout(() => {
              if (asyncFilter()) {
                this.triggerCycle(el, DEBOUNCE_TRIGGER, currentCycle);
              }
            }, timeout);
          }
          const form = el.form;
          if (form && this.once(form, "bind-debounce")) {
            form.addEventListener("submit", () => {
              Array.from(new FormData(form).entries(), ([name]) => {
                const namedItem = form.elements.namedItem(name);
                const input = namedItem instanceof RadioNodeList ? namedItem[0] : namedItem;
                if (input) {
                  this.incCycle(input, DEBOUNCE_TRIGGER);
                  this.deletePrivate(input, THROTTLED);
                }
              });
            });
          }
          if (this.once(el, "bind-debounce")) {
            el.addEventListener("blur", () => {
              clearTimeout(this.private(el, THROTTLED));
              this.triggerCycle(el, DEBOUNCE_TRIGGER);
            });
          }
      }
    },
    triggerCycle(el, key, currentCycle) {
      const [cycle, trigger] = this.private(el, key);
      if (!currentCycle) {
        currentCycle = cycle;
      }
      if (currentCycle === cycle) {
        this.incCycle(el, key);
        trigger();
      }
    },
    once(el, key) {
      if (this.private(el, key) === true) {
        return false;
      }
      this.putPrivate(el, key, true);
      return true;
    },
    incCycle(el, key, trigger = function() {
    }) {
      let [currentCycle] = this.private(el, key) || [0, trigger];
      currentCycle++;
      this.putPrivate(el, key, [currentCycle, trigger]);
      return currentCycle;
    },
    // maintains or adds privately used hook information
    // fromEl and toEl can be the same element in the case of a newly added node
    // fromEl and toEl can be any HTML node type, so we need to check if it's an element node
    maintainPrivateHooks(fromEl, toEl, phxViewportTop, phxViewportBottom) {
      if (fromEl.hasAttribute && fromEl.hasAttribute("data-phx-hook") && !toEl.hasAttribute("data-phx-hook")) {
        toEl.setAttribute("data-phx-hook", fromEl.getAttribute("data-phx-hook"));
      }
      if (toEl.hasAttribute && (toEl.hasAttribute(phxViewportTop) || toEl.hasAttribute(phxViewportBottom))) {
        toEl.setAttribute("data-phx-hook", "Phoenix.InfiniteScroll");
      }
    },
    putCustomElHook(el, hook) {
      if (el.isConnected) {
        el.setAttribute("data-phx-hook", "");
      } else {
        console.error(`
        hook attached to non-connected DOM element
        ensure you are calling createHook within your connectedCallback. ${el.outerHTML}
      `);
      }
      this.putPrivate(el, "custom-el-hook", hook);
    },
    getCustomElHook(el) {
      return this.private(el, "custom-el-hook");
    },
    isUsedInput(el) {
      return el.nodeType === Node.ELEMENT_NODE && (this.private(el, PHX_HAS_FOCUSED) || this.private(el, PHX_HAS_SUBMITTED));
    },
    resetForm(form) {
      Array.from(form.elements).forEach((input) => {
        this.deletePrivate(input, PHX_HAS_FOCUSED);
        this.deletePrivate(input, PHX_HAS_SUBMITTED);
      });
    },
    isPhxChild(node) {
      return node.getAttribute && node.getAttribute(PHX_PARENT_ID);
    },
    isPhxSticky(node) {
      return node.getAttribute && node.getAttribute(PHX_STICKY) !== null;
    },
    isChildOfAny(el, parents) {
      return !!parents.find((parent) => parent.contains(el));
    },
    firstPhxChild(el) {
      return this.isPhxChild(el) ? el : this.all(el, `[${PHX_PARENT_ID}]`)[0];
    },
    isPortalTemplate(el) {
      return el.tagName === "TEMPLATE" && el.hasAttribute(PHX_PORTAL);
    },
    closestViewEl(el) {
      const portalOrViewEl = el.closest(
        `[${PHX_TELEPORTED_REF}],${PHX_VIEW_SELECTOR}`
      );
      if (!portalOrViewEl) {
        return null;
      }
      if (portalOrViewEl.hasAttribute(PHX_TELEPORTED_REF)) {
        return this.byId(portalOrViewEl.getAttribute(PHX_TELEPORTED_REF));
      } else if (portalOrViewEl.hasAttribute(PHX_SESSION)) {
        return portalOrViewEl;
      }
      return null;
    },
    dispatchEvent(target, name, opts = {}) {
      let defaultBubble = true;
      const isUploadTarget = target.nodeName === "INPUT" && target.type === "file";
      if (isUploadTarget && name === "click") {
        defaultBubble = false;
      }
      const bubbles = opts.bubbles === void 0 ? defaultBubble : !!opts.bubbles;
      const eventOpts = {
        bubbles,
        cancelable: true,
        detail: opts.detail || {}
      };
      const event = name === "click" ? new MouseEvent("click", eventOpts) : new CustomEvent(name, eventOpts);
      target.dispatchEvent(event);
    },
    cloneNode(node, html) {
      if (typeof html === "undefined") {
        return node.cloneNode(true);
      } else {
        const cloned = node.cloneNode(false);
        cloned.innerHTML = html;
        return cloned;
      }
    },
    // merge attributes from source to target
    // if an element is ignored, we only merge data attributes
    // including removing data attributes that are no longer in the source
    mergeAttrs(target, source, opts = {}) {
      const exclude = new Set(opts.exclude || []);
      const isIgnored = opts.isIgnored;
      const sourceAttrs = source.attributes;
      for (let i = sourceAttrs.length - 1; i >= 0; i--) {
        const name = sourceAttrs[i].name;
        if (!exclude.has(name)) {
          const sourceValue = source.getAttribute(name);
          if (target.getAttribute(name) !== sourceValue && (!isIgnored || isIgnored && name.startsWith("data-"))) {
            target.setAttribute(name, sourceValue);
          }
        } else {
          if (name === "value") {
            const sourceValue = source.value ?? source.getAttribute(name);
            if (target.value === sourceValue) {
              target.setAttribute("value", source.getAttribute(name));
            }
          }
        }
      }
      const targetAttrs = target.attributes;
      for (let i = targetAttrs.length - 1; i >= 0; i--) {
        const name = targetAttrs[i].name;
        if (isIgnored) {
          if (name.startsWith("data-") && !source.hasAttribute(name) && !PHX_PENDING_ATTRS.includes(name)) {
            target.removeAttribute(name);
          }
        } else {
          if (!source.hasAttribute(name)) {
            target.removeAttribute(name);
          }
        }
      }
    },
    mergeFocusedInput(target, source) {
      if (!(target instanceof HTMLSelectElement)) {
        DOM.mergeAttrs(target, source, { exclude: ["value"] });
      }
      if (source.readOnly) {
        target.setAttribute("readonly", true);
      } else {
        target.removeAttribute("readonly");
      }
    },
    hasSelectionRange(el) {
      return el.setSelectionRange && (el.type === "text" || el.type === "textarea");
    },
    restoreFocus(focused, selectionStart, selectionEnd) {
      if (focused instanceof HTMLSelectElement) {
        focused.focus();
      }
      if (!DOM.isTextualInput(focused)) {
        return;
      }
      const wasFocused = focused.matches(":focus");
      if (!wasFocused) {
        focused.focus();
      }
      if (this.hasSelectionRange(focused)) {
        focused.setSelectionRange(selectionStart, selectionEnd);
      }
    },
    isFormInput(el) {
      if (el.localName && customElements.get(el.localName)) {
        return customElements.get(el.localName)[`formAssociated`];
      }
      return /^(?:input|select|textarea)$/i.test(el.tagName) && el.type !== "button";
    },
    syncAttrsToProps(el) {
      if (el instanceof HTMLInputElement && CHECKABLE_INPUTS.indexOf(el.type.toLocaleLowerCase()) >= 0) {
        el.checked = el.getAttribute("checked") !== null;
      }
    },
    isTextualInput(el) {
      return FOCUSABLE_INPUTS.indexOf(el.type) >= 0;
    },
    isNowTriggerFormExternal(el, phxTriggerExternal) {
      return el.getAttribute && el.getAttribute(phxTriggerExternal) !== null && document.body.contains(el);
    },
    cleanChildNodes(container, phxUpdate) {
      if (DOM.isPhxUpdate(container, phxUpdate, ["append", "prepend", PHX_STREAM])) {
        const toRemove = [];
        container.childNodes.forEach((childNode) => {
          if (!childNode.id) {
            const isEmptyTextNode = childNode.nodeType === Node.TEXT_NODE && childNode.nodeValue.trim() === "";
            if (!isEmptyTextNode && childNode.nodeType !== Node.COMMENT_NODE) {
              logError(
                `only HTML element tags with an id are allowed inside containers with phx-update.

removing illegal node: "${(childNode.outerHTML || childNode.nodeValue).trim()}"

`
              );
            }
            toRemove.push(childNode);
          }
        });
        toRemove.forEach((childNode) => childNode.remove());
      }
    },
    replaceRootContainer(container, tagName, attrs) {
      const retainedAttrs = /* @__PURE__ */ new Set([
        "id",
        PHX_SESSION,
        PHX_STATIC,
        PHX_MAIN,
        PHX_ROOT_ID
      ]);
      if (container.tagName.toLowerCase() === tagName.toLowerCase()) {
        Array.from(container.attributes).filter((attr) => !retainedAttrs.has(attr.name.toLowerCase())).forEach((attr) => container.removeAttribute(attr.name));
        Object.keys(attrs).filter((name) => !retainedAttrs.has(name.toLowerCase())).forEach((attr) => container.setAttribute(attr, attrs[attr]));
        return container;
      } else {
        const newContainer = document.createElement(tagName);
        Object.keys(attrs).forEach(
          (attr) => newContainer.setAttribute(attr, attrs[attr])
        );
        retainedAttrs.forEach(
          (attr) => newContainer.setAttribute(attr, container.getAttribute(attr))
        );
        newContainer.innerHTML = container.innerHTML;
        container.replaceWith(newContainer);
        return newContainer;
      }
    },
    getSticky(el, name, defaultVal) {
      const op = (DOM.private(el, "sticky") || []).find(
        ([existingName]) => name === existingName
      );
      if (op) {
        const [_name, _op, stashedResult] = op;
        return stashedResult;
      } else {
        return typeof defaultVal === "function" ? defaultVal() : defaultVal;
      }
    },
    deleteSticky(el, name) {
      this.updatePrivate(el, "sticky", [], (ops) => {
        return ops.filter(([existingName, _]) => existingName !== name);
      });
    },
    putSticky(el, name, op) {
      const stashedResult = op(el);
      this.updatePrivate(el, "sticky", [], (ops) => {
        const existingIndex = ops.findIndex(
          ([existingName]) => name === existingName
        );
        if (existingIndex >= 0) {
          ops[existingIndex] = [name, op, stashedResult];
        } else {
          ops.push([name, op, stashedResult]);
        }
        return ops;
      });
    },
    applyStickyOperations(el) {
      const ops = DOM.private(el, "sticky");
      if (!ops) {
        return;
      }
      ops.forEach(([name, op, _stashed]) => this.putSticky(el, name, op));
    },
    isLocked(el) {
      return el.hasAttribute && el.hasAttribute(PHX_REF_LOCK);
    },
    attributeIgnored(attribute, ignoredAttributes) {
      return ignoredAttributes.some(
        (toIgnore) => attribute.name == toIgnore || toIgnore === "*" || toIgnore.includes("*") && attribute.name.match(toIgnore) != null
      );
    }
  };
  var dom_default = DOM;
  var UploadEntry = class {
    static isActive(fileEl, file) {
      const isNew = file._phxRef === void 0;
      const activeRefs = fileEl.getAttribute(PHX_ACTIVE_ENTRY_REFS).split(",");
      const isActive = activeRefs.indexOf(LiveUploader.genFileRef(file)) >= 0;
      return file.size > 0 && (isNew || isActive);
    }
    static isPreflighted(fileEl, file) {
      const preflightedRefs = fileEl.getAttribute(PHX_PREFLIGHTED_REFS).split(",");
      const isPreflighted = preflightedRefs.indexOf(LiveUploader.genFileRef(file)) >= 0;
      return isPreflighted && this.isActive(fileEl, file);
    }
    static isPreflightInProgress(file) {
      return file._preflightInProgress === true;
    }
    static markPreflightInProgress(file) {
      file._preflightInProgress = true;
    }
    constructor(fileEl, file, view, autoUpload) {
      this.ref = LiveUploader.genFileRef(file);
      this.fileEl = fileEl;
      this.file = file;
      this.view = view;
      this.meta = null;
      this._isCancelled = false;
      this._isDone = false;
      this._progress = 0;
      this._lastProgressSent = -1;
      this._onDone = function() {
      };
      this._onElUpdated = this.onElUpdated.bind(this);
      this.fileEl.addEventListener(PHX_LIVE_FILE_UPDATED, this._onElUpdated);
      this.autoUpload = autoUpload;
    }
    metadata() {
      return this.meta;
    }
    progress(progress) {
      this._progress = Math.floor(progress);
      if (this._progress > this._lastProgressSent) {
        if (this._progress >= 100) {
          this._progress = 100;
          this._lastProgressSent = 100;
          this._isDone = true;
          this.view.pushFileProgress(this.fileEl, this.ref, 100, () => {
            LiveUploader.untrackFile(this.fileEl, this.file);
            this._onDone();
          });
        } else {
          this._lastProgressSent = this._progress;
          this.view.pushFileProgress(this.fileEl, this.ref, this._progress);
        }
      }
    }
    isCancelled() {
      return this._isCancelled;
    }
    cancel() {
      this.file._preflightInProgress = false;
      this._isCancelled = true;
      this._isDone = true;
      this._onDone();
    }
    isDone() {
      return this._isDone;
    }
    error(reason = "failed") {
      this.fileEl.removeEventListener(PHX_LIVE_FILE_UPDATED, this._onElUpdated);
      this.view.pushFileProgress(this.fileEl, this.ref, { error: reason });
      if (!this.isAutoUpload()) {
        LiveUploader.clearFiles(this.fileEl);
      }
    }
    isAutoUpload() {
      return this.autoUpload;
    }
    //private
    onDone(callback) {
      this._onDone = () => {
        this.fileEl.removeEventListener(PHX_LIVE_FILE_UPDATED, this._onElUpdated);
        callback();
      };
    }
    onElUpdated() {
      const activeRefs = this.fileEl.getAttribute(PHX_ACTIVE_ENTRY_REFS).split(",");
      if (activeRefs.indexOf(this.ref) === -1) {
        LiveUploader.untrackFile(this.fileEl, this.file);
        this.cancel();
      }
    }
    toPreflightPayload() {
      return {
        last_modified: this.file.lastModified,
        name: this.file.name,
        relative_path: this.file.webkitRelativePath,
        size: this.file.size,
        type: this.file.type,
        ref: this.ref,
        meta: typeof this.file.meta === "function" ? this.file.meta() : void 0
      };
    }
    uploader(uploaders) {
      if (this.meta.uploader) {
        const callback = uploaders[this.meta.uploader] || logError(`no uploader configured for ${this.meta.uploader}`);
        return { name: this.meta.uploader, callback };
      } else {
        return { name: "channel", callback: channelUploader };
      }
    }
    zipPostFlight(resp) {
      this.meta = resp.entries[this.ref];
      if (!this.meta) {
        logError(`no preflight upload response returned with ref ${this.ref}`, {
          input: this.fileEl,
          response: resp
        });
      }
    }
  };
  var liveUploaderFileRef = 0;
  var LiveUploader = class _LiveUploader {
    static genFileRef(file) {
      const ref = file._phxRef;
      if (ref !== void 0) {
        return ref;
      } else {
        file._phxRef = (liveUploaderFileRef++).toString();
        return file._phxRef;
      }
    }
    static getEntryDataURL(inputEl, ref, callback) {
      const file = this.activeFiles(inputEl).find(
        (file2) => this.genFileRef(file2) === ref
      );
      callback(URL.createObjectURL(file));
    }
    static hasUploadsInProgress(formEl) {
      let active = 0;
      dom_default.findUploadInputs(formEl).forEach((input) => {
        if (input.getAttribute(PHX_PREFLIGHTED_REFS) !== input.getAttribute(PHX_DONE_REFS)) {
          active++;
        }
      });
      return active > 0;
    }
    static serializeUploads(inputEl) {
      const files = this.activeFiles(inputEl);
      const fileData = {};
      files.forEach((file) => {
        const entry = { path: inputEl.name };
        const uploadRef = inputEl.getAttribute(PHX_UPLOAD_REF);
        fileData[uploadRef] = fileData[uploadRef] || [];
        entry.ref = this.genFileRef(file);
        entry.last_modified = file.lastModified;
        entry.name = file.name || entry.ref;
        entry.relative_path = file.webkitRelativePath;
        entry.type = file.type;
        entry.size = file.size;
        if (typeof file.meta === "function") {
          entry.meta = file.meta();
        }
        fileData[uploadRef].push(entry);
      });
      return fileData;
    }
    static clearFiles(inputEl) {
      inputEl.value = null;
      inputEl.removeAttribute(PHX_UPLOAD_REF);
      dom_default.putPrivate(inputEl, "files", []);
    }
    static untrackFile(inputEl, file) {
      dom_default.putPrivate(
        inputEl,
        "files",
        dom_default.private(inputEl, "files").filter((f) => !Object.is(f, file))
      );
    }
    /**
     * @param {HTMLInputElement} inputEl
     * @param {Array<File|Blob>} files
     * @param {DataTransfer} [dataTransfer]
     */
    static trackFiles(inputEl, files, dataTransfer) {
      if (inputEl.getAttribute("multiple") !== null) {
        const newFiles = files.filter(
          (file) => !this.activeFiles(inputEl).find((f) => Object.is(f, file))
        );
        dom_default.updatePrivate(
          inputEl,
          "files",
          [],
          (existing) => existing.concat(newFiles)
        );
        inputEl.value = null;
      } else {
        if (dataTransfer && dataTransfer.files.length > 0) {
          inputEl.files = dataTransfer.files;
        }
        dom_default.putPrivate(inputEl, "files", files);
      }
    }
    static activeFileInputs(formEl) {
      const fileInputs = dom_default.findUploadInputs(formEl);
      return Array.from(fileInputs).filter(
        (el) => el.files && this.activeFiles(el).length > 0
      );
    }
    static activeFiles(input) {
      return (dom_default.private(input, "files") || []).filter(
        (f) => UploadEntry.isActive(input, f)
      );
    }
    static inputsAwaitingPreflight(formEl) {
      const fileInputs = dom_default.findUploadInputs(formEl);
      return Array.from(fileInputs).filter(
        (input) => this.filesAwaitingPreflight(input).length > 0
      );
    }
    static filesAwaitingPreflight(input) {
      return this.activeFiles(input).filter(
        (f) => !UploadEntry.isPreflighted(input, f) && !UploadEntry.isPreflightInProgress(f)
      );
    }
    static markPreflightInProgress(entries) {
      entries.forEach((entry) => UploadEntry.markPreflightInProgress(entry.file));
    }
    constructor(inputEl, view, onComplete) {
      this.autoUpload = dom_default.isAutoUpload(inputEl);
      this.view = view;
      this.onComplete = onComplete;
      this._entries = Array.from(
        _LiveUploader.filesAwaitingPreflight(inputEl) || []
      ).map((file) => new UploadEntry(inputEl, file, view, this.autoUpload));
      _LiveUploader.markPreflightInProgress(this._entries);
      this.numEntriesInProgress = this._entries.length;
    }
    isAutoUpload() {
      return this.autoUpload;
    }
    entries() {
      return this._entries;
    }
    initAdapterUpload(resp, onError, liveSocket2) {
      this._entries = this._entries.map((entry) => {
        if (entry.isCancelled()) {
          this.numEntriesInProgress--;
          if (this.numEntriesInProgress === 0) {
            this.onComplete();
          }
        } else {
          entry.zipPostFlight(resp);
          entry.onDone(() => {
            this.numEntriesInProgress--;
            if (this.numEntriesInProgress === 0) {
              this.onComplete();
            }
          });
        }
        return entry;
      });
      const groupedEntries = this._entries.reduce((acc, entry) => {
        if (!entry.meta) {
          return acc;
        }
        const { name, callback } = entry.uploader(liveSocket2.uploaders);
        acc[name] = acc[name] || { callback, entries: [] };
        acc[name].entries.push(entry);
        return acc;
      }, {});
      for (const name in groupedEntries) {
        const { callback, entries } = groupedEntries[name];
        callback(entries, onError, resp, liveSocket2);
      }
    }
  };
  var ARIA = {
    anyOf(instance, classes) {
      return classes.find((name) => instance instanceof name);
    },
    isFocusable(el, interactiveOnly) {
      return el instanceof HTMLAnchorElement && el.rel !== "ignore" || el instanceof HTMLAreaElement && el.href !== void 0 || !el.disabled && this.anyOf(el, [
        HTMLInputElement,
        HTMLSelectElement,
        HTMLTextAreaElement,
        HTMLButtonElement
      ]) || el instanceof HTMLIFrameElement || el.tabIndex >= 0 && el.getAttribute("aria-hidden") !== "true" || !interactiveOnly && el.getAttribute("tabindex") !== null && el.getAttribute("aria-hidden") !== "true";
    },
    attemptFocus(el, interactiveOnly) {
      if (this.isFocusable(el, interactiveOnly)) {
        try {
          el.focus();
        } catch {
        }
      }
      return !!document.activeElement && document.activeElement.isSameNode(el);
    },
    focusFirstInteractive(el) {
      let child = el.firstElementChild;
      while (child) {
        if (this.attemptFocus(child, true) || this.focusFirstInteractive(child)) {
          return true;
        }
        child = child.nextElementSibling;
      }
    },
    focusFirst(el) {
      let child = el.firstElementChild;
      while (child) {
        if (this.attemptFocus(child) || this.focusFirst(child)) {
          return true;
        }
        child = child.nextElementSibling;
      }
    },
    focusLast(el) {
      let child = el.lastElementChild;
      while (child) {
        if (this.attemptFocus(child) || this.focusLast(child)) {
          return true;
        }
        child = child.previousElementSibling;
      }
    }
  };
  var aria_default = ARIA;
  var Hooks = {
    LiveFileUpload: {
      activeRefs() {
        return this.el.getAttribute(PHX_ACTIVE_ENTRY_REFS);
      },
      preflightedRefs() {
        return this.el.getAttribute(PHX_PREFLIGHTED_REFS);
      },
      mounted() {
        this.js().ignoreAttributes(this.el, ["value"]);
        this.preflightedWas = this.preflightedRefs();
      },
      updated() {
        const newPreflights = this.preflightedRefs();
        if (this.preflightedWas !== newPreflights) {
          this.preflightedWas = newPreflights;
          if (newPreflights === "") {
            this.__view().cancelSubmit(this.el.form);
          }
        }
        if (this.activeRefs() === "") {
          this.el.value = null;
        }
        this.el.dispatchEvent(new CustomEvent(PHX_LIVE_FILE_UPDATED));
      }
    },
    LiveImgPreview: {
      mounted() {
        this.ref = this.el.getAttribute("data-phx-entry-ref");
        this.inputEl = document.getElementById(
          this.el.getAttribute(PHX_UPLOAD_REF)
        );
        LiveUploader.getEntryDataURL(this.inputEl, this.ref, (url) => {
          this.url = url;
          this.el.src = url;
        });
      },
      destroyed() {
        URL.revokeObjectURL(this.url);
      }
    },
    FocusWrap: {
      mounted() {
        this.focusStart = this.el.firstElementChild;
        this.focusEnd = this.el.lastElementChild;
        this.focusStart.addEventListener("focus", (e) => {
          if (!e.relatedTarget || !this.el.contains(e.relatedTarget)) {
            const nextFocus = e.target.nextElementSibling;
            aria_default.attemptFocus(nextFocus) || aria_default.focusFirst(nextFocus);
          } else {
            aria_default.focusLast(this.el);
          }
        });
        this.focusEnd.addEventListener("focus", (e) => {
          if (!e.relatedTarget || !this.el.contains(e.relatedTarget)) {
            const nextFocus = e.target.previousElementSibling;
            aria_default.attemptFocus(nextFocus) || aria_default.focusLast(nextFocus);
          } else {
            aria_default.focusFirst(this.el);
          }
        });
        if (!this.el.contains(document.activeElement)) {
          this.el.addEventListener("phx:show-end", () => this.el.focus());
          if (window.getComputedStyle(this.el).display !== "none") {
            aria_default.focusFirst(this.el);
          }
        }
      }
    }
  };
  var findScrollContainer = (el) => {
    if (["HTML", "BODY"].indexOf(el.nodeName.toUpperCase()) >= 0)
      return null;
    if (["scroll", "auto"].indexOf(getComputedStyle(el).overflowY) >= 0)
      return el;
    return findScrollContainer(el.parentElement);
  };
  var scrollTop = (scrollContainer) => {
    if (scrollContainer) {
      return scrollContainer.scrollTop;
    } else {
      return document.documentElement.scrollTop || document.body.scrollTop;
    }
  };
  var bottom = (scrollContainer) => {
    if (scrollContainer) {
      return scrollContainer.getBoundingClientRect().bottom;
    } else {
      return window.innerHeight || document.documentElement.clientHeight;
    }
  };
  var top = (scrollContainer) => {
    if (scrollContainer) {
      return scrollContainer.getBoundingClientRect().top;
    } else {
      return 0;
    }
  };
  var isAtViewportTop = (el, scrollContainer) => {
    const rect = el.getBoundingClientRect();
    return Math.ceil(rect.top) >= top(scrollContainer) && Math.ceil(rect.left) >= 0 && Math.floor(rect.top) <= bottom(scrollContainer);
  };
  var isAtViewportBottom = (el, scrollContainer) => {
    const rect = el.getBoundingClientRect();
    return Math.ceil(rect.bottom) >= top(scrollContainer) && Math.ceil(rect.left) >= 0 && Math.floor(rect.bottom) <= bottom(scrollContainer);
  };
  var isWithinViewport = (el, scrollContainer) => {
    const rect = el.getBoundingClientRect();
    return Math.ceil(rect.top) >= top(scrollContainer) && Math.ceil(rect.left) >= 0 && Math.floor(rect.top) <= bottom(scrollContainer);
  };
  Hooks.InfiniteScroll = {
    mounted() {
      this.scrollContainer = findScrollContainer(this.el);
      let scrollBefore = scrollTop(this.scrollContainer);
      let topOverran = false;
      const throttleInterval = 500;
      let pendingOp = null;
      const onTopOverrun = this.throttle(
        throttleInterval,
        (topEvent, firstChild) => {
          pendingOp = () => true;
          this.liveSocket.js().push(this.el, topEvent, {
            value: { id: firstChild.id, _overran: true },
            callback: () => {
              pendingOp = null;
            }
          });
        }
      );
      const onFirstChildAtTop = this.throttle(
        throttleInterval,
        (topEvent, firstChild) => {
          pendingOp = () => firstChild.scrollIntoView({ block: "start" });
          this.liveSocket.js().push(this.el, topEvent, {
            value: { id: firstChild.id },
            callback: () => {
              pendingOp = null;
              window.requestAnimationFrame(() => {
                if (!isWithinViewport(firstChild, this.scrollContainer)) {
                  firstChild.scrollIntoView({ block: "start" });
                }
              });
            }
          });
        }
      );
      const onLastChildAtBottom = this.throttle(
        throttleInterval,
        (bottomEvent, lastChild) => {
          pendingOp = () => lastChild.scrollIntoView({ block: "end" });
          this.liveSocket.js().push(this.el, bottomEvent, {
            value: { id: lastChild.id },
            callback: () => {
              pendingOp = null;
              window.requestAnimationFrame(() => {
                if (!isWithinViewport(lastChild, this.scrollContainer)) {
                  lastChild.scrollIntoView({ block: "end" });
                }
              });
            }
          });
        }
      );
      this.onScroll = (_e) => {
        const scrollNow = scrollTop(this.scrollContainer);
        if (pendingOp) {
          scrollBefore = scrollNow;
          return pendingOp();
        }
        const rect = this.findOverrunTarget();
        const topEvent = this.el.getAttribute(
          this.liveSocket.binding("viewport-top")
        );
        const bottomEvent = this.el.getAttribute(
          this.liveSocket.binding("viewport-bottom")
        );
        const lastChild = this.el.lastElementChild;
        const firstChild = this.el.firstElementChild;
        const isScrollingUp = scrollNow < scrollBefore;
        const isScrollingDown = scrollNow > scrollBefore;
        if (isScrollingUp && topEvent && !topOverran && rect.top >= 0) {
          topOverran = true;
          onTopOverrun(topEvent, firstChild);
        } else if (isScrollingDown && topOverran && rect.top <= 0) {
          topOverran = false;
        }
        if (topEvent && isScrollingUp && isAtViewportTop(firstChild, this.scrollContainer)) {
          onFirstChildAtTop(topEvent, firstChild);
        } else if (bottomEvent && isScrollingDown && isAtViewportBottom(lastChild, this.scrollContainer)) {
          onLastChildAtBottom(bottomEvent, lastChild);
        }
        scrollBefore = scrollNow;
      };
      if (this.scrollContainer) {
        this.scrollContainer.addEventListener("scroll", this.onScroll);
      } else {
        window.addEventListener("scroll", this.onScroll);
      }
    },
    destroyed() {
      if (this.scrollContainer) {
        this.scrollContainer.removeEventListener("scroll", this.onScroll);
      } else {
        window.removeEventListener("scroll", this.onScroll);
      }
    },
    throttle(interval, callback) {
      let lastCallAt = 0;
      let timer;
      return (...args) => {
        const now = Date.now();
        const remainingTime = interval - (now - lastCallAt);
        if (remainingTime <= 0 || remainingTime > interval) {
          if (timer) {
            clearTimeout(timer);
            timer = null;
          }
          lastCallAt = now;
          callback(...args);
        } else if (!timer) {
          timer = setTimeout(() => {
            lastCallAt = Date.now();
            timer = null;
            callback(...args);
          }, remainingTime);
        }
      };
    },
    findOverrunTarget() {
      let rect;
      const overrunTarget = this.el.getAttribute(
        this.liveSocket.binding(PHX_VIEWPORT_OVERRUN_TARGET)
      );
      if (overrunTarget) {
        const overrunEl = document.getElementById(overrunTarget);
        if (overrunEl) {
          rect = overrunEl.getBoundingClientRect();
        } else {
          throw new Error("did not find element with id " + overrunTarget);
        }
      } else {
        rect = this.el.getBoundingClientRect();
      }
      return rect;
    }
  };
  var hooks_default = Hooks;
  var ElementRef = class {
    static onUnlock(el, callback) {
      if (!dom_default.isLocked(el) && !el.closest(`[${PHX_REF_LOCK}]`)) {
        return callback();
      }
      const closestLock = el.closest(`[${PHX_REF_LOCK}]`);
      const ref = closestLock.closest(`[${PHX_REF_LOCK}]`).getAttribute(PHX_REF_LOCK);
      closestLock.addEventListener(
        `phx:undo-lock:${ref}`,
        () => {
          callback();
        },
        { once: true }
      );
    }
    constructor(el) {
      this.el = el;
      this.loadingRef = el.hasAttribute(PHX_REF_LOADING) ? parseInt(el.getAttribute(PHX_REF_LOADING), 10) : null;
      this.lockRef = el.hasAttribute(PHX_REF_LOCK) ? parseInt(el.getAttribute(PHX_REF_LOCK), 10) : null;
    }
    // public
    maybeUndo(ref, phxEvent, eachCloneCallback) {
      if (!this.isWithin(ref)) {
        dom_default.updatePrivate(this.el, PHX_PENDING_REFS, [], (pendingRefs) => {
          pendingRefs.push(ref);
          return pendingRefs;
        });
        return;
      }
      this.undoLocks(ref, phxEvent, eachCloneCallback);
      this.undoLoading(ref, phxEvent);
      dom_default.updatePrivate(this.el, PHX_PENDING_REFS, [], (pendingRefs) => {
        return pendingRefs.filter((pendingRef) => {
          let opts = {
            detail: { ref: pendingRef, event: phxEvent },
            bubbles: true,
            cancelable: false
          };
          if (this.loadingRef && this.loadingRef > pendingRef) {
            this.el.dispatchEvent(
              new CustomEvent(`phx:undo-loading:${pendingRef}`, opts)
            );
          }
          if (this.lockRef && this.lockRef > pendingRef) {
            this.el.dispatchEvent(
              new CustomEvent(`phx:undo-lock:${pendingRef}`, opts)
            );
          }
          return pendingRef > ref;
        });
      });
      if (this.isFullyResolvedBy(ref)) {
        this.el.removeAttribute(PHX_REF_SRC);
      }
    }
    // private
    isWithin(ref) {
      return !(this.loadingRef !== null && this.loadingRef > ref && this.lockRef !== null && this.lockRef > ref);
    }
    // Check for cloned PHX_REF_LOCK element that has been morphed behind
    // the scenes while this element was locked in the DOM.
    // When we apply the cloned tree to the active DOM element, we must
    //
    //   1. execute pending mounted hooks for nodes now in the DOM
    //   2. undo any ref inside the cloned tree that has since been ack'd
    undoLocks(ref, phxEvent, eachCloneCallback) {
      if (!this.isLockUndoneBy(ref)) {
        return;
      }
      const clonedTree = dom_default.private(this.el, PHX_REF_LOCK);
      if (clonedTree) {
        eachCloneCallback(clonedTree);
        dom_default.deletePrivate(this.el, PHX_REF_LOCK);
      }
      this.el.removeAttribute(PHX_REF_LOCK);
      const opts = {
        detail: { ref, event: phxEvent },
        bubbles: true,
        cancelable: false
      };
      this.el.dispatchEvent(
        new CustomEvent(`phx:undo-lock:${this.lockRef}`, opts)
      );
    }
    undoLoading(ref, phxEvent) {
      if (!this.isLoadingUndoneBy(ref)) {
        if (this.canUndoLoading(ref) && this.el.classList.contains("phx-submit-loading")) {
          this.el.classList.remove("phx-change-loading");
        }
        return;
      }
      if (this.canUndoLoading(ref)) {
        this.el.removeAttribute(PHX_REF_LOADING);
        const disabledVal = this.el.getAttribute(PHX_DISABLED);
        const readOnlyVal = this.el.getAttribute(PHX_READONLY);
        if (readOnlyVal !== null) {
          this.el.readOnly = readOnlyVal === "true" ? true : false;
          this.el.removeAttribute(PHX_READONLY);
        }
        if (disabledVal !== null) {
          this.el.disabled = disabledVal === "true" ? true : false;
          this.el.removeAttribute(PHX_DISABLED);
        }
        const disableRestore = this.el.getAttribute(PHX_DISABLE_WITH_RESTORE);
        if (disableRestore !== null) {
          this.el.textContent = disableRestore;
          this.el.removeAttribute(PHX_DISABLE_WITH_RESTORE);
        }
        const opts = {
          detail: { ref, event: phxEvent },
          bubbles: true,
          cancelable: false
        };
        this.el.dispatchEvent(
          new CustomEvent(`phx:undo-loading:${this.loadingRef}`, opts)
        );
      }
      PHX_EVENT_CLASSES.forEach((name) => {
        if (name !== "phx-submit-loading" || this.canUndoLoading(ref)) {
          dom_default.removeClass(this.el, name);
        }
      });
    }
    isLoadingUndoneBy(ref) {
      return this.loadingRef === null ? false : this.loadingRef <= ref;
    }
    isLockUndoneBy(ref) {
      return this.lockRef === null ? false : this.lockRef <= ref;
    }
    isFullyResolvedBy(ref) {
      return (this.loadingRef === null || this.loadingRef <= ref) && (this.lockRef === null || this.lockRef <= ref);
    }
    // only remove the phx-submit-loading class if we are not locked
    canUndoLoading(ref) {
      return this.lockRef === null || this.lockRef <= ref;
    }
  };
  var DOMPostMorphRestorer = class {
    constructor(containerBefore, containerAfter, updateType) {
      const idsBefore = /* @__PURE__ */ new Set();
      const idsAfter = new Set(
        [...containerAfter.children].map((child) => child.id)
      );
      const elementsToModify = [];
      Array.from(containerBefore.children).forEach((child) => {
        if (child.id) {
          idsBefore.add(child.id);
          if (idsAfter.has(child.id)) {
            const previousElementId = child.previousElementSibling && child.previousElementSibling.id;
            elementsToModify.push({
              elementId: child.id,
              previousElementId
            });
          }
        }
      });
      this.containerId = containerAfter.id;
      this.updateType = updateType;
      this.elementsToModify = elementsToModify;
      this.elementIdsToAdd = [...idsAfter].filter((id) => !idsBefore.has(id));
    }
    // We do the following to optimize append/prepend operations:
    //   1) Track ids of modified elements & of new elements
    //   2) All the modified elements are put back in the correct position in the DOM tree
    //      by storing the id of their previous sibling
    //   3) New elements are going to be put in the right place by morphdom during append.
    //      For prepend, we move them to the first position in the container
    perform() {
      const container = dom_default.byId(this.containerId);
      if (!container) {
        return;
      }
      this.elementsToModify.forEach((elementToModify) => {
        if (elementToModify.previousElementId) {
          maybe(
            document.getElementById(elementToModify.previousElementId),
            (previousElem) => {
              maybe(
                document.getElementById(elementToModify.elementId),
                (elem) => {
                  const isInRightPlace = elem.previousElementSibling && elem.previousElementSibling.id == previousElem.id;
                  if (!isInRightPlace) {
                    previousElem.insertAdjacentElement("afterend", elem);
                  }
                }
              );
            }
          );
        } else {
          maybe(document.getElementById(elementToModify.elementId), (elem) => {
            const isInRightPlace = elem.previousElementSibling == null;
            if (!isInRightPlace) {
              container.insertAdjacentElement("afterbegin", elem);
            }
          });
        }
      });
      if (this.updateType == "prepend") {
        this.elementIdsToAdd.reverse().forEach((elemId) => {
          maybe(
            document.getElementById(elemId),
            (elem) => container.insertAdjacentElement("afterbegin", elem)
          );
        });
      }
    }
  };
  var DOCUMENT_FRAGMENT_NODE = 11;
  function morphAttrs(fromNode, toNode) {
    var toNodeAttrs = toNode.attributes;
    var attr;
    var attrName;
    var attrNamespaceURI;
    var attrValue;
    var fromValue;
    if (toNode.nodeType === DOCUMENT_FRAGMENT_NODE || fromNode.nodeType === DOCUMENT_FRAGMENT_NODE) {
      return;
    }
    for (var i = toNodeAttrs.length - 1; i >= 0; i--) {
      attr = toNodeAttrs[i];
      attrName = attr.name;
      attrNamespaceURI = attr.namespaceURI;
      attrValue = attr.value;
      if (attrNamespaceURI) {
        attrName = attr.localName || attrName;
        fromValue = fromNode.getAttributeNS(attrNamespaceURI, attrName);
        if (fromValue !== attrValue) {
          if (attr.prefix === "xmlns") {
            attrName = attr.name;
          }
          fromNode.setAttributeNS(attrNamespaceURI, attrName, attrValue);
        }
      } else {
        fromValue = fromNode.getAttribute(attrName);
        if (fromValue !== attrValue) {
          fromNode.setAttribute(attrName, attrValue);
        }
      }
    }
    var fromNodeAttrs = fromNode.attributes;
    for (var d = fromNodeAttrs.length - 1; d >= 0; d--) {
      attr = fromNodeAttrs[d];
      attrName = attr.name;
      attrNamespaceURI = attr.namespaceURI;
      if (attrNamespaceURI) {
        attrName = attr.localName || attrName;
        if (!toNode.hasAttributeNS(attrNamespaceURI, attrName)) {
          fromNode.removeAttributeNS(attrNamespaceURI, attrName);
        }
      } else {
        if (!toNode.hasAttribute(attrName)) {
          fromNode.removeAttribute(attrName);
        }
      }
    }
  }
  var range;
  var NS_XHTML = "http://www.w3.org/1999/xhtml";
  var doc = typeof document === "undefined" ? void 0 : document;
  var HAS_TEMPLATE_SUPPORT = !!doc && "content" in doc.createElement("template");
  var HAS_RANGE_SUPPORT = !!doc && doc.createRange && "createContextualFragment" in doc.createRange();
  function createFragmentFromTemplate(str) {
    var template = doc.createElement("template");
    template.innerHTML = str;
    return template.content.childNodes[0];
  }
  function createFragmentFromRange(str) {
    if (!range) {
      range = doc.createRange();
      range.selectNode(doc.body);
    }
    var fragment = range.createContextualFragment(str);
    return fragment.childNodes[0];
  }
  function createFragmentFromWrap(str) {
    var fragment = doc.createElement("body");
    fragment.innerHTML = str;
    return fragment.childNodes[0];
  }
  function toElement(str) {
    str = str.trim();
    if (HAS_TEMPLATE_SUPPORT) {
      return createFragmentFromTemplate(str);
    } else if (HAS_RANGE_SUPPORT) {
      return createFragmentFromRange(str);
    }
    return createFragmentFromWrap(str);
  }
  function compareNodeNames(fromEl, toEl) {
    var fromNodeName = fromEl.nodeName;
    var toNodeName = toEl.nodeName;
    var fromCodeStart, toCodeStart;
    if (fromNodeName === toNodeName) {
      return true;
    }
    fromCodeStart = fromNodeName.charCodeAt(0);
    toCodeStart = toNodeName.charCodeAt(0);
    if (fromCodeStart <= 90 && toCodeStart >= 97) {
      return fromNodeName === toNodeName.toUpperCase();
    } else if (toCodeStart <= 90 && fromCodeStart >= 97) {
      return toNodeName === fromNodeName.toUpperCase();
    } else {
      return false;
    }
  }
  function createElementNS(name, namespaceURI) {
    return !namespaceURI || namespaceURI === NS_XHTML ? doc.createElement(name) : doc.createElementNS(namespaceURI, name);
  }
  function moveChildren(fromEl, toEl) {
    var curChild = fromEl.firstChild;
    while (curChild) {
      var nextChild = curChild.nextSibling;
      toEl.appendChild(curChild);
      curChild = nextChild;
    }
    return toEl;
  }
  function syncBooleanAttrProp(fromEl, toEl, name) {
    if (fromEl[name] !== toEl[name]) {
      fromEl[name] = toEl[name];
      if (fromEl[name]) {
        fromEl.setAttribute(name, "");
      } else {
        fromEl.removeAttribute(name);
      }
    }
  }
  var specialElHandlers = {
    OPTION: function(fromEl, toEl) {
      var parentNode = fromEl.parentNode;
      if (parentNode) {
        var parentName = parentNode.nodeName.toUpperCase();
        if (parentName === "OPTGROUP") {
          parentNode = parentNode.parentNode;
          parentName = parentNode && parentNode.nodeName.toUpperCase();
        }
        if (parentName === "SELECT" && !parentNode.hasAttribute("multiple")) {
          if (fromEl.hasAttribute("selected") && !toEl.selected) {
            fromEl.setAttribute("selected", "selected");
            fromEl.removeAttribute("selected");
          }
          parentNode.selectedIndex = -1;
        }
      }
      syncBooleanAttrProp(fromEl, toEl, "selected");
    },
    /**
     * The "value" attribute is special for the <input> element since it sets
     * the initial value. Changing the "value" attribute without changing the
     * "value" property will have no effect since it is only used to the set the
     * initial value.  Similar for the "checked" attribute, and "disabled".
     */
    INPUT: function(fromEl, toEl) {
      syncBooleanAttrProp(fromEl, toEl, "checked");
      syncBooleanAttrProp(fromEl, toEl, "disabled");
      if (fromEl.value !== toEl.value) {
        fromEl.value = toEl.value;
      }
      if (!toEl.hasAttribute("value")) {
        fromEl.removeAttribute("value");
      }
    },
    TEXTAREA: function(fromEl, toEl) {
      var newValue = toEl.value;
      if (fromEl.value !== newValue) {
        fromEl.value = newValue;
      }
      var firstChild = fromEl.firstChild;
      if (firstChild) {
        var oldValue = firstChild.nodeValue;
        if (oldValue == newValue || !newValue && oldValue == fromEl.placeholder) {
          return;
        }
        firstChild.nodeValue = newValue;
      }
    },
    SELECT: function(fromEl, toEl) {
      if (!toEl.hasAttribute("multiple")) {
        var selectedIndex = -1;
        var i = 0;
        var curChild = fromEl.firstChild;
        var optgroup;
        var nodeName;
        while (curChild) {
          nodeName = curChild.nodeName && curChild.nodeName.toUpperCase();
          if (nodeName === "OPTGROUP") {
            optgroup = curChild;
            curChild = optgroup.firstChild;
            if (!curChild) {
              curChild = optgroup.nextSibling;
              optgroup = null;
            }
          } else {
            if (nodeName === "OPTION") {
              if (curChild.hasAttribute("selected")) {
                selectedIndex = i;
                break;
              }
              i++;
            }
            curChild = curChild.nextSibling;
            if (!curChild && optgroup) {
              curChild = optgroup.nextSibling;
              optgroup = null;
            }
          }
        }
        fromEl.selectedIndex = selectedIndex;
      }
    }
  };
  var ELEMENT_NODE = 1;
  var DOCUMENT_FRAGMENT_NODE$1 = 11;
  var TEXT_NODE = 3;
  var COMMENT_NODE = 8;
  function noop() {
  }
  function defaultGetNodeKey(node) {
    if (node) {
      return node.getAttribute && node.getAttribute("id") || node.id;
    }
  }
  function morphdomFactory(morphAttrs2) {
    return function morphdom2(fromNode, toNode, options) {
      if (!options) {
        options = {};
      }
      if (typeof toNode === "string") {
        if (fromNode.nodeName === "#document" || fromNode.nodeName === "HTML") {
          var toNodeHtml = toNode;
          toNode = doc.createElement("html");
          toNode.innerHTML = toNodeHtml;
        } else if (fromNode.nodeName === "BODY") {
          var toNodeBody = toNode;
          toNode = doc.createElement("html");
          toNode.innerHTML = toNodeBody;
          var bodyElement = toNode.querySelector("body");
          if (bodyElement) {
            toNode = bodyElement;
          }
        } else {
          toNode = toElement(toNode);
        }
      } else if (toNode.nodeType === DOCUMENT_FRAGMENT_NODE$1) {
        toNode = toNode.firstElementChild;
      }
      var getNodeKey = options.getNodeKey || defaultGetNodeKey;
      var onBeforeNodeAdded = options.onBeforeNodeAdded || noop;
      var onNodeAdded = options.onNodeAdded || noop;
      var onBeforeElUpdated = options.onBeforeElUpdated || noop;
      var onElUpdated = options.onElUpdated || noop;
      var onBeforeNodeDiscarded = options.onBeforeNodeDiscarded || noop;
      var onNodeDiscarded = options.onNodeDiscarded || noop;
      var onBeforeElChildrenUpdated = options.onBeforeElChildrenUpdated || noop;
      var skipFromChildren = options.skipFromChildren || noop;
      var addChild = options.addChild || function(parent, child) {
        return parent.appendChild(child);
      };
      var childrenOnly = options.childrenOnly === true;
      var fromNodesLookup = /* @__PURE__ */ Object.create(null);
      var keyedRemovalList = [];
      function addKeyedRemoval(key) {
        keyedRemovalList.push(key);
      }
      function walkDiscardedChildNodes(node, skipKeyedNodes) {
        if (node.nodeType === ELEMENT_NODE) {
          var curChild = node.firstChild;
          while (curChild) {
            var key = void 0;
            if (skipKeyedNodes && (key = getNodeKey(curChild))) {
              addKeyedRemoval(key);
            } else {
              onNodeDiscarded(curChild);
              if (curChild.firstChild) {
                walkDiscardedChildNodes(curChild, skipKeyedNodes);
              }
            }
            curChild = curChild.nextSibling;
          }
        }
      }
      function removeNode(node, parentNode, skipKeyedNodes) {
        if (onBeforeNodeDiscarded(node) === false) {
          return;
        }
        if (parentNode) {
          parentNode.removeChild(node);
        }
        onNodeDiscarded(node);
        walkDiscardedChildNodes(node, skipKeyedNodes);
      }
      function indexTree(node) {
        if (node.nodeType === ELEMENT_NODE || node.nodeType === DOCUMENT_FRAGMENT_NODE$1) {
          var curChild = node.firstChild;
          while (curChild) {
            var key = getNodeKey(curChild);
            if (key) {
              fromNodesLookup[key] = curChild;
            }
            indexTree(curChild);
            curChild = curChild.nextSibling;
          }
        }
      }
      indexTree(fromNode);
      function handleNodeAdded(el) {
        onNodeAdded(el);
        var curChild = el.firstChild;
        while (curChild) {
          var nextSibling = curChild.nextSibling;
          var key = getNodeKey(curChild);
          if (key) {
            var unmatchedFromEl = fromNodesLookup[key];
            if (unmatchedFromEl && compareNodeNames(curChild, unmatchedFromEl)) {
              curChild.parentNode.replaceChild(unmatchedFromEl, curChild);
              morphEl(unmatchedFromEl, curChild);
            } else {
              handleNodeAdded(curChild);
            }
          } else {
            handleNodeAdded(curChild);
          }
          curChild = nextSibling;
        }
      }
      function cleanupFromEl(fromEl, curFromNodeChild, curFromNodeKey) {
        while (curFromNodeChild) {
          var fromNextSibling = curFromNodeChild.nextSibling;
          if (curFromNodeKey = getNodeKey(curFromNodeChild)) {
            addKeyedRemoval(curFromNodeKey);
          } else {
            removeNode(
              curFromNodeChild,
              fromEl,
              true
              /* skip keyed nodes */
            );
          }
          curFromNodeChild = fromNextSibling;
        }
      }
      function morphEl(fromEl, toEl, childrenOnly2) {
        var toElKey = getNodeKey(toEl);
        if (toElKey) {
          delete fromNodesLookup[toElKey];
        }
        if (!childrenOnly2) {
          var beforeUpdateResult = onBeforeElUpdated(fromEl, toEl);
          if (beforeUpdateResult === false) {
            return;
          } else if (beforeUpdateResult instanceof HTMLElement) {
            fromEl = beforeUpdateResult;
            indexTree(fromEl);
          }
          morphAttrs2(fromEl, toEl);
          onElUpdated(fromEl);
          if (onBeforeElChildrenUpdated(fromEl, toEl) === false) {
            return;
          }
        }
        if (fromEl.nodeName !== "TEXTAREA") {
          morphChildren(fromEl, toEl);
        } else {
          specialElHandlers.TEXTAREA(fromEl, toEl);
        }
      }
      function morphChildren(fromEl, toEl) {
        var skipFrom = skipFromChildren(fromEl, toEl);
        var curToNodeChild = toEl.firstChild;
        var curFromNodeChild = fromEl.firstChild;
        var curToNodeKey;
        var curFromNodeKey;
        var fromNextSibling;
        var toNextSibling;
        var matchingFromEl;
        outer:
          while (curToNodeChild) {
            toNextSibling = curToNodeChild.nextSibling;
            curToNodeKey = getNodeKey(curToNodeChild);
            while (!skipFrom && curFromNodeChild) {
              fromNextSibling = curFromNodeChild.nextSibling;
              if (curToNodeChild.isSameNode && curToNodeChild.isSameNode(curFromNodeChild)) {
                curToNodeChild = toNextSibling;
                curFromNodeChild = fromNextSibling;
                continue outer;
              }
              curFromNodeKey = getNodeKey(curFromNodeChild);
              var curFromNodeType = curFromNodeChild.nodeType;
              var isCompatible = void 0;
              if (curFromNodeType === curToNodeChild.nodeType) {
                if (curFromNodeType === ELEMENT_NODE) {
                  if (curToNodeKey) {
                    if (curToNodeKey !== curFromNodeKey) {
                      if (matchingFromEl = fromNodesLookup[curToNodeKey]) {
                        if (fromNextSibling === matchingFromEl) {
                          isCompatible = false;
                        } else {
                          fromEl.insertBefore(matchingFromEl, curFromNodeChild);
                          if (curFromNodeKey) {
                            addKeyedRemoval(curFromNodeKey);
                          } else {
                            removeNode(
                              curFromNodeChild,
                              fromEl,
                              true
                              /* skip keyed nodes */
                            );
                          }
                          curFromNodeChild = matchingFromEl;
                          curFromNodeKey = getNodeKey(curFromNodeChild);
                        }
                      } else {
                        isCompatible = false;
                      }
                    }
                  } else if (curFromNodeKey) {
                    isCompatible = false;
                  }
                  isCompatible = isCompatible !== false && compareNodeNames(curFromNodeChild, curToNodeChild);
                  if (isCompatible) {
                    morphEl(curFromNodeChild, curToNodeChild);
                  }
                } else if (curFromNodeType === TEXT_NODE || curFromNodeType == COMMENT_NODE) {
                  isCompatible = true;
                  if (curFromNodeChild.nodeValue !== curToNodeChild.nodeValue) {
                    curFromNodeChild.nodeValue = curToNodeChild.nodeValue;
                  }
                }
              }
              if (isCompatible) {
                curToNodeChild = toNextSibling;
                curFromNodeChild = fromNextSibling;
                continue outer;
              }
              if (curFromNodeKey) {
                addKeyedRemoval(curFromNodeKey);
              } else {
                removeNode(
                  curFromNodeChild,
                  fromEl,
                  true
                  /* skip keyed nodes */
                );
              }
              curFromNodeChild = fromNextSibling;
            }
            if (curToNodeKey && (matchingFromEl = fromNodesLookup[curToNodeKey]) && compareNodeNames(matchingFromEl, curToNodeChild)) {
              if (!skipFrom) {
                addChild(fromEl, matchingFromEl);
              }
              morphEl(matchingFromEl, curToNodeChild);
            } else {
              var onBeforeNodeAddedResult = onBeforeNodeAdded(curToNodeChild);
              if (onBeforeNodeAddedResult !== false) {
                if (onBeforeNodeAddedResult) {
                  curToNodeChild = onBeforeNodeAddedResult;
                }
                if (curToNodeChild.actualize) {
                  curToNodeChild = curToNodeChild.actualize(fromEl.ownerDocument || doc);
                }
                addChild(fromEl, curToNodeChild);
                handleNodeAdded(curToNodeChild);
              }
            }
            curToNodeChild = toNextSibling;
            curFromNodeChild = fromNextSibling;
          }
        cleanupFromEl(fromEl, curFromNodeChild, curFromNodeKey);
        var specialElHandler = specialElHandlers[fromEl.nodeName];
        if (specialElHandler) {
          specialElHandler(fromEl, toEl);
        }
      }
      var morphedNode = fromNode;
      var morphedNodeType = morphedNode.nodeType;
      var toNodeType = toNode.nodeType;
      if (!childrenOnly) {
        if (morphedNodeType === ELEMENT_NODE) {
          if (toNodeType === ELEMENT_NODE) {
            if (!compareNodeNames(fromNode, toNode)) {
              onNodeDiscarded(fromNode);
              morphedNode = moveChildren(fromNode, createElementNS(toNode.nodeName, toNode.namespaceURI));
            }
          } else {
            morphedNode = toNode;
          }
        } else if (morphedNodeType === TEXT_NODE || morphedNodeType === COMMENT_NODE) {
          if (toNodeType === morphedNodeType) {
            if (morphedNode.nodeValue !== toNode.nodeValue) {
              morphedNode.nodeValue = toNode.nodeValue;
            }
            return morphedNode;
          } else {
            morphedNode = toNode;
          }
        }
      }
      if (morphedNode === toNode) {
        onNodeDiscarded(fromNode);
      } else {
        if (toNode.isSameNode && toNode.isSameNode(morphedNode)) {
          return;
        }
        morphEl(morphedNode, toNode, childrenOnly);
        if (keyedRemovalList) {
          for (var i = 0, len = keyedRemovalList.length; i < len; i++) {
            var elToRemove = fromNodesLookup[keyedRemovalList[i]];
            if (elToRemove) {
              removeNode(elToRemove, elToRemove.parentNode, false);
            }
          }
        }
      }
      if (!childrenOnly && morphedNode !== fromNode && fromNode.parentNode) {
        if (morphedNode.actualize) {
          morphedNode = morphedNode.actualize(fromNode.ownerDocument || doc);
        }
        fromNode.parentNode.replaceChild(morphedNode, fromNode);
      }
      return morphedNode;
    };
  }
  var morphdom = morphdomFactory(morphAttrs);
  var morphdom_esm_default = morphdom;
  var DOMPatch = class {
    constructor(view, container, id, html, streams, targetCID, opts = {}) {
      this.view = view;
      this.liveSocket = view.liveSocket;
      this.container = container;
      this.id = id;
      this.rootID = view.root.id;
      this.html = html;
      this.streams = streams;
      this.streamInserts = {};
      this.streamComponentRestore = {};
      this.targetCID = targetCID;
      this.cidPatch = isCid(this.targetCID);
      this.pendingRemoves = [];
      this.phxRemove = this.liveSocket.binding("remove");
      this.targetContainer = this.isCIDPatch() ? this.targetCIDContainer(html) : container;
      this.callbacks = {
        beforeadded: [],
        beforeupdated: [],
        beforephxChildAdded: [],
        afteradded: [],
        afterupdated: [],
        afterdiscarded: [],
        afterphxChildAdded: [],
        aftertransitionsDiscarded: []
      };
      this.withChildren = opts.withChildren || opts.undoRef || false;
      this.undoRef = opts.undoRef;
    }
    before(kind, callback) {
      this.callbacks[`before${kind}`].push(callback);
    }
    after(kind, callback) {
      this.callbacks[`after${kind}`].push(callback);
    }
    trackBefore(kind, ...args) {
      this.callbacks[`before${kind}`].forEach((callback) => callback(...args));
    }
    trackAfter(kind, ...args) {
      this.callbacks[`after${kind}`].forEach((callback) => callback(...args));
    }
    markPrunableContentForRemoval() {
      const phxUpdate = this.liveSocket.binding(PHX_UPDATE);
      dom_default.all(
        this.container,
        `[${phxUpdate}=append] > *, [${phxUpdate}=prepend] > *`,
        (el) => {
          el.setAttribute(PHX_PRUNE, "");
        }
      );
    }
    perform(isJoinPatch) {
      const { view, liveSocket: liveSocket2, html, container } = this;
      let targetContainer = this.targetContainer;
      if (this.isCIDPatch() && !this.targetContainer) {
        return;
      }
      if (this.isCIDPatch()) {
        const closestLock = targetContainer.closest(`[${PHX_REF_LOCK}]`);
        if (closestLock && !closestLock.isSameNode(targetContainer)) {
          const clonedTree = dom_default.private(closestLock, PHX_REF_LOCK);
          if (clonedTree) {
            targetContainer = clonedTree.querySelector(
              `[data-phx-component="${this.targetCID}"]`
            );
          }
        }
      }
      const focused = liveSocket2.getActiveElement();
      const { selectionStart, selectionEnd } = focused && dom_default.hasSelectionRange(focused) ? focused : {};
      const phxUpdate = liveSocket2.binding(PHX_UPDATE);
      const phxViewportTop = liveSocket2.binding(PHX_VIEWPORT_TOP);
      const phxViewportBottom = liveSocket2.binding(PHX_VIEWPORT_BOTTOM);
      const phxTriggerExternal = liveSocket2.binding(PHX_TRIGGER_ACTION);
      const added = [];
      const updates = [];
      const appendPrependUpdates = [];
      let portalCallbacks = [];
      let externalFormTriggered = null;
      const morph = (targetContainer2, source, withChildren = this.withChildren) => {
        const morphCallbacks = {
          // normally, we are running with childrenOnly, as the patch HTML for a LV
          // does not include the LV attrs (data-phx-session, etc.)
          // when we are patching a live component, we do want to patch the root element as well;
          // another case is the recursive patch of a stream item that was kept on reset (-> onBeforeNodeAdded)
          childrenOnly: targetContainer2.getAttribute(PHX_COMPONENT) === null && !withChildren,
          getNodeKey: (node) => {
            if (dom_default.isPhxDestroyed(node)) {
              return null;
            }
            if (isJoinPatch) {
              return node.id;
            }
            return node.id || node.getAttribute && node.getAttribute(PHX_MAGIC_ID);
          },
          // skip indexing from children when container is stream
          skipFromChildren: (from) => {
            return from.getAttribute(phxUpdate) === PHX_STREAM;
          },
          // tell morphdom how to add a child
          addChild: (parent, child) => {
            const { ref, streamAt } = this.getStreamInsert(child);
            if (ref === void 0) {
              return parent.appendChild(child);
            }
            this.setStreamRef(child, ref);
            if (streamAt === 0) {
              parent.insertAdjacentElement("afterbegin", child);
            } else if (streamAt === -1) {
              const lastChild = parent.lastElementChild;
              if (lastChild && !lastChild.hasAttribute(PHX_STREAM_REF)) {
                const nonStreamChild = Array.from(parent.children).find(
                  (c) => !c.hasAttribute(PHX_STREAM_REF)
                );
                parent.insertBefore(child, nonStreamChild);
              } else {
                parent.appendChild(child);
              }
            } else if (streamAt > 0) {
              const sibling = Array.from(parent.children)[streamAt];
              parent.insertBefore(child, sibling);
            }
          },
          onBeforeNodeAdded: (el) => {
            if (this.getStreamInsert(el)?.updateOnly && !this.streamComponentRestore[el.id]) {
              return false;
            }
            dom_default.maintainPrivateHooks(el, el, phxViewportTop, phxViewportBottom);
            this.trackBefore("added", el);
            let morphedEl = el;
            if (this.streamComponentRestore[el.id]) {
              morphedEl = this.streamComponentRestore[el.id];
              delete this.streamComponentRestore[el.id];
              morph(morphedEl, el, true);
            }
            return morphedEl;
          },
          onNodeAdded: (el) => {
            if (el.getAttribute) {
              this.maybeReOrderStream(el, true);
            }
            if (dom_default.isPortalTemplate(el)) {
              portalCallbacks.push(() => this.teleport(el, morph));
            }
            if (el instanceof HTMLImageElement && el.srcset) {
              el.srcset = el.srcset;
            } else if (el instanceof HTMLVideoElement && el.autoplay) {
              el.play();
            }
            if (dom_default.isNowTriggerFormExternal(el, phxTriggerExternal)) {
              externalFormTriggered = el;
            }
            if (dom_default.isPhxChild(el) && view.ownsElement(el) || dom_default.isPhxSticky(el) && view.ownsElement(el.parentNode)) {
              this.trackAfter("phxChildAdded", el);
            }
            if (el.nodeName === "SCRIPT" && el.hasAttribute(PHX_RUNTIME_HOOK)) {
              this.handleRuntimeHook(el, source);
            }
            added.push(el);
          },
          onNodeDiscarded: (el) => this.onNodeDiscarded(el),
          onBeforeNodeDiscarded: (el) => {
            if (el.getAttribute && el.getAttribute(PHX_PRUNE) !== null) {
              return true;
            }
            if (el.parentElement !== null && el.id && dom_default.isPhxUpdate(el.parentElement, phxUpdate, [
              PHX_STREAM,
              "append",
              "prepend"
            ])) {
              return false;
            }
            if (el.getAttribute && el.getAttribute(PHX_TELEPORTED_REF)) {
              return false;
            }
            if (this.maybePendingRemove(el)) {
              return false;
            }
            if (this.skipCIDSibling(el)) {
              return false;
            }
            if (dom_default.isPortalTemplate(el)) {
              const teleportedEl = document.getElementById(
                el.content.firstElementChild.id
              );
              if (teleportedEl) {
                teleportedEl.remove();
                morphCallbacks.onNodeDiscarded(teleportedEl);
                this.view.dropPortalElementId(teleportedEl.id);
              }
            }
            return true;
          },
          onElUpdated: (el) => {
            if (dom_default.isNowTriggerFormExternal(el, phxTriggerExternal)) {
              externalFormTriggered = el;
            }
            updates.push(el);
            this.maybeReOrderStream(el, false);
          },
          onBeforeElUpdated: (fromEl, toEl) => {
            if (fromEl.id && fromEl.isSameNode(targetContainer2) && fromEl.id !== toEl.id) {
              morphCallbacks.onNodeDiscarded(fromEl);
              fromEl.replaceWith(toEl);
              return morphCallbacks.onNodeAdded(toEl);
            }
            dom_default.syncPendingAttrs(fromEl, toEl);
            dom_default.maintainPrivateHooks(
              fromEl,
              toEl,
              phxViewportTop,
              phxViewportBottom
            );
            dom_default.cleanChildNodes(toEl, phxUpdate);
            if (this.skipCIDSibling(toEl)) {
              this.maybeReOrderStream(fromEl);
              return false;
            }
            if (dom_default.isPhxSticky(fromEl)) {
              [PHX_SESSION, PHX_STATIC, PHX_ROOT_ID].map((attr) => [
                attr,
                fromEl.getAttribute(attr),
                toEl.getAttribute(attr)
              ]).forEach(([attr, fromVal, toVal]) => {
                if (toVal && fromVal !== toVal) {
                  fromEl.setAttribute(attr, toVal);
                }
              });
              return false;
            }
            if (dom_default.isIgnored(fromEl, phxUpdate) || fromEl.form && fromEl.form.isSameNode(externalFormTriggered)) {
              this.trackBefore("updated", fromEl, toEl);
              dom_default.mergeAttrs(fromEl, toEl, {
                isIgnored: dom_default.isIgnored(fromEl, phxUpdate)
              });
              updates.push(fromEl);
              dom_default.applyStickyOperations(fromEl);
              return false;
            }
            if (fromEl.type === "number" && fromEl.validity && fromEl.validity.badInput) {
              return false;
            }
            const isFocusedFormEl = focused && fromEl.isSameNode(focused) && dom_default.isFormInput(fromEl);
            const focusedSelectChanged = isFocusedFormEl && this.isChangedSelect(fromEl, toEl);
            if (fromEl.hasAttribute(PHX_REF_SRC)) {
              const ref = new ElementRef(fromEl);
              if (ref.lockRef && (!this.undoRef || !ref.isLockUndoneBy(this.undoRef))) {
                dom_default.applyStickyOperations(fromEl);
                const isLocked = fromEl.hasAttribute(PHX_REF_LOCK);
                const clone2 = isLocked ? dom_default.private(fromEl, PHX_REF_LOCK) || fromEl.cloneNode(true) : null;
                if (clone2) {
                  dom_default.putPrivate(fromEl, PHX_REF_LOCK, clone2);
                  if (!isFocusedFormEl) {
                    fromEl = clone2;
                  }
                }
              }
            }
            if (dom_default.isPhxChild(toEl)) {
              const prevSession = fromEl.getAttribute(PHX_SESSION);
              dom_default.mergeAttrs(fromEl, toEl, { exclude: [PHX_STATIC] });
              if (prevSession !== "") {
                fromEl.setAttribute(PHX_SESSION, prevSession);
              }
              fromEl.setAttribute(PHX_ROOT_ID, this.rootID);
              dom_default.applyStickyOperations(fromEl);
              return false;
            }
            if (this.undoRef && dom_default.private(toEl, PHX_REF_LOCK)) {
              dom_default.putPrivate(
                fromEl,
                PHX_REF_LOCK,
                dom_default.private(toEl, PHX_REF_LOCK)
              );
            }
            dom_default.copyPrivates(toEl, fromEl);
            if (dom_default.isPortalTemplate(toEl)) {
              portalCallbacks.push(() => this.teleport(toEl, morph));
              fromEl.innerHTML = toEl.innerHTML;
              return false;
            }
            if (isFocusedFormEl && fromEl.type !== "hidden" && !focusedSelectChanged) {
              this.trackBefore("updated", fromEl, toEl);
              dom_default.mergeFocusedInput(fromEl, toEl);
              dom_default.syncAttrsToProps(fromEl);
              updates.push(fromEl);
              dom_default.applyStickyOperations(fromEl);
              return false;
            } else {
              if (focusedSelectChanged) {
                fromEl.blur();
              }
              if (dom_default.isPhxUpdate(toEl, phxUpdate, ["append", "prepend"])) {
                appendPrependUpdates.push(
                  new DOMPostMorphRestorer(
                    fromEl,
                    toEl,
                    toEl.getAttribute(phxUpdate)
                  )
                );
              }
              dom_default.syncAttrsToProps(toEl);
              dom_default.applyStickyOperations(toEl);
              this.trackBefore("updated", fromEl, toEl);
              return fromEl;
            }
          }
        };
        morphdom_esm_default(targetContainer2, source, morphCallbacks);
      };
      this.trackBefore("added", container);
      this.trackBefore("updated", container, container);
      liveSocket2.time("morphdom", () => {
        this.streams.forEach(([ref, inserts, deleteIds, reset]) => {
          inserts.forEach(([key, streamAt, limit, updateOnly]) => {
            this.streamInserts[key] = { ref, streamAt, limit, reset, updateOnly };
          });
          if (reset !== void 0) {
            dom_default.all(document, `[${PHX_STREAM_REF}="${ref}"]`, (child) => {
              this.removeStreamChildElement(child);
            });
          }
          deleteIds.forEach((id) => {
            const child = document.getElementById(id);
            if (child) {
              this.removeStreamChildElement(child);
            }
          });
        });
        if (isJoinPatch) {
          dom_default.all(this.container, `[${phxUpdate}=${PHX_STREAM}]`).filter((el) => this.view.ownsElement(el)).forEach((el) => {
            Array.from(el.children).forEach((child) => {
              this.removeStreamChildElement(child, true);
            });
          });
        }
        morph(targetContainer, html);
        let teleportCount = 0;
        while (portalCallbacks.length > 0 && teleportCount < 5) {
          const copy = portalCallbacks.slice();
          portalCallbacks = [];
          copy.forEach((callback) => callback());
          teleportCount++;
        }
        this.view.portalElementIds.forEach((id) => {
          const el = document.getElementById(id);
          if (el) {
            const source = document.getElementById(
              el.getAttribute(PHX_TELEPORTED_SRC)
            );
            if (!source) {
              el.remove();
              this.onNodeDiscarded(el);
              this.view.dropPortalElementId(id);
            }
          }
        });
      });
      if (liveSocket2.isDebugEnabled()) {
        detectDuplicateIds();
        detectInvalidStreamInserts(this.streamInserts);
        Array.from(document.querySelectorAll("input[name=id]")).forEach(
          (node) => {
            if (node instanceof HTMLInputElement && node.form) {
              console.error(
                'Detected an input with name="id" inside a form! This will cause problems when patching the DOM.\n',
                node
              );
            }
          }
        );
      }
      if (appendPrependUpdates.length > 0) {
        liveSocket2.time("post-morph append/prepend restoration", () => {
          appendPrependUpdates.forEach((update) => update.perform());
        });
      }
      liveSocket2.silenceEvents(
        () => dom_default.restoreFocus(focused, selectionStart, selectionEnd)
      );
      dom_default.dispatchEvent(document, "phx:update");
      added.forEach((el) => this.trackAfter("added", el));
      updates.forEach((el) => this.trackAfter("updated", el));
      this.transitionPendingRemoves();
      if (externalFormTriggered) {
        liveSocket2.unload();
        const submitter = dom_default.private(externalFormTriggered, "submitter");
        if (submitter && submitter.name && targetContainer.contains(submitter)) {
          const input = document.createElement("input");
          input.type = "hidden";
          const formId = submitter.getAttribute("form");
          if (formId) {
            input.setAttribute("form", formId);
          }
          input.name = submitter.name;
          input.value = submitter.value;
          submitter.parentElement.insertBefore(input, submitter);
        }
        Object.getPrototypeOf(externalFormTriggered).submit.call(
          externalFormTriggered
        );
      }
      return true;
    }
    onNodeDiscarded(el) {
      if (dom_default.isPhxChild(el) || dom_default.isPhxSticky(el)) {
        this.liveSocket.destroyViewByEl(el);
      }
      this.trackAfter("discarded", el);
    }
    maybePendingRemove(node) {
      if (node.getAttribute && node.getAttribute(this.phxRemove) !== null) {
        this.pendingRemoves.push(node);
        return true;
      } else {
        return false;
      }
    }
    removeStreamChildElement(child, force = false) {
      if (!force && !this.view.ownsElement(child)) {
        return;
      }
      if (this.streamInserts[child.id]) {
        this.streamComponentRestore[child.id] = child;
        child.remove();
      } else {
        if (!this.maybePendingRemove(child)) {
          child.remove();
          this.onNodeDiscarded(child);
        }
      }
    }
    getStreamInsert(el) {
      const insert = el.id ? this.streamInserts[el.id] : {};
      return insert || {};
    }
    setStreamRef(el, ref) {
      dom_default.putSticky(
        el,
        PHX_STREAM_REF,
        (el2) => el2.setAttribute(PHX_STREAM_REF, ref)
      );
    }
    maybeReOrderStream(el, isNew) {
      const { ref, streamAt, reset } = this.getStreamInsert(el);
      if (streamAt === void 0) {
        return;
      }
      this.setStreamRef(el, ref);
      if (!reset && !isNew) {
        return;
      }
      if (!el.parentElement) {
        return;
      }
      if (streamAt === 0) {
        el.parentElement.insertBefore(el, el.parentElement.firstElementChild);
      } else if (streamAt > 0) {
        const children = Array.from(el.parentElement.children);
        const oldIndex = children.indexOf(el);
        if (streamAt >= children.length - 1) {
          el.parentElement.appendChild(el);
        } else {
          const sibling = children[streamAt];
          if (oldIndex > streamAt) {
            el.parentElement.insertBefore(el, sibling);
          } else {
            el.parentElement.insertBefore(el, sibling.nextElementSibling);
          }
        }
      }
      this.maybeLimitStream(el);
    }
    maybeLimitStream(el) {
      const { limit } = this.getStreamInsert(el);
      const children = limit !== null && Array.from(el.parentElement.children);
      if (limit && limit < 0 && children.length > limit * -1) {
        children.slice(0, children.length + limit).forEach((child) => this.removeStreamChildElement(child));
      } else if (limit && limit >= 0 && children.length > limit) {
        children.slice(limit).forEach((child) => this.removeStreamChildElement(child));
      }
    }
    transitionPendingRemoves() {
      const { pendingRemoves, liveSocket: liveSocket2 } = this;
      if (pendingRemoves.length > 0) {
        liveSocket2.transitionRemoves(pendingRemoves, () => {
          pendingRemoves.forEach((el) => {
            const child = dom_default.firstPhxChild(el);
            if (child) {
              liveSocket2.destroyViewByEl(child);
            }
            el.remove();
          });
          this.trackAfter("transitionsDiscarded", pendingRemoves);
        });
      }
    }
    isChangedSelect(fromEl, toEl) {
      if (!(fromEl instanceof HTMLSelectElement) || fromEl.multiple) {
        return false;
      }
      if (fromEl.options.length !== toEl.options.length) {
        return true;
      }
      toEl.value = fromEl.value;
      return !fromEl.isEqualNode(toEl);
    }
    isCIDPatch() {
      return this.cidPatch;
    }
    skipCIDSibling(el) {
      return el.nodeType === Node.ELEMENT_NODE && el.hasAttribute(PHX_SKIP);
    }
    targetCIDContainer(html) {
      if (!this.isCIDPatch()) {
        return;
      }
      const [first, ...rest] = dom_default.findComponentNodeList(
        this.view.id,
        this.targetCID
      );
      if (rest.length === 0 && dom_default.childNodeLength(html) === 1) {
        return first;
      } else {
        return first && first.parentNode;
      }
    }
    indexOf(parent, child) {
      return Array.from(parent.children).indexOf(child);
    }
    teleport(el, morph) {
      const targetSelector = el.getAttribute(PHX_PORTAL);
      const portalContainer = document.querySelector(targetSelector);
      if (!portalContainer) {
        throw new Error(
          "portal target with selector " + targetSelector + " not found"
        );
      }
      const toTeleport = el.content.firstElementChild;
      if (this.skipCIDSibling(toTeleport)) {
        return;
      }
      if (!toTeleport?.id) {
        throw new Error(
          "phx-portal template must have a single root element with ID!"
        );
      }
      const existing = document.getElementById(toTeleport.id);
      let portalTarget;
      if (existing) {
        if (!portalContainer.contains(existing)) {
          portalContainer.appendChild(existing);
        }
        portalTarget = existing;
      } else {
        portalTarget = document.createElement(toTeleport.tagName);
        portalContainer.appendChild(portalTarget);
      }
      toTeleport.setAttribute(PHX_TELEPORTED_REF, this.view.id);
      toTeleport.setAttribute(PHX_TELEPORTED_SRC, el.id);
      morph(portalTarget, toTeleport, true);
      toTeleport.removeAttribute(PHX_TELEPORTED_REF);
      toTeleport.removeAttribute(PHX_TELEPORTED_SRC);
      this.view.pushPortalElementId(toTeleport.id);
    }
    handleRuntimeHook(el, source) {
      const name = el.getAttribute(PHX_RUNTIME_HOOK);
      let nonce = el.hasAttribute("nonce") ? el.getAttribute("nonce") : null;
      if (el.hasAttribute("nonce")) {
        const template = document.createElement("template");
        template.innerHTML = source;
        nonce = template.content.querySelector(`script[${PHX_RUNTIME_HOOK}="${CSS.escape(name)}"]`).getAttribute("nonce");
      }
      const script = document.createElement("script");
      script.textContent = el.textContent;
      dom_default.mergeAttrs(script, el, { isIgnored: false });
      if (nonce) {
        script.nonce = nonce;
      }
      el.replaceWith(script);
      el = script;
    }
  };
  var VOID_TAGS = /* @__PURE__ */ new Set([
    "area",
    "base",
    "br",
    "col",
    "command",
    "embed",
    "hr",
    "img",
    "input",
    "keygen",
    "link",
    "meta",
    "param",
    "source",
    "track",
    "wbr"
  ]);
  var quoteChars = /* @__PURE__ */ new Set(["'", '"']);
  var modifyRoot = (html, attrs, clearInnerHTML) => {
    let i = 0;
    let insideComment = false;
    let beforeTag, afterTag, tag, tagNameEndsAt, id, newHTML;
    const lookahead = html.match(/^(\s*(?:<!--.*?-->\s*)*)<([^\s\/>]+)/);
    if (lookahead === null) {
      throw new Error(`malformed html ${html}`);
    }
    i = lookahead[0].length;
    beforeTag = lookahead[1];
    tag = lookahead[2];
    tagNameEndsAt = i;
    for (i; i < html.length; i++) {
      if (html.charAt(i) === ">") {
        break;
      }
      if (html.charAt(i) === "=") {
        const isId = html.slice(i - 3, i) === " id";
        i++;
        const char = html.charAt(i);
        if (quoteChars.has(char)) {
          const attrStartsAt = i;
          i++;
          for (i; i < html.length; i++) {
            if (html.charAt(i) === char) {
              break;
            }
          }
          if (isId) {
            id = html.slice(attrStartsAt + 1, i);
            break;
          }
        }
      }
    }
    let closeAt = html.length - 1;
    insideComment = false;
    while (closeAt >= beforeTag.length + tag.length) {
      const char = html.charAt(closeAt);
      if (insideComment) {
        if (char === "-" && html.slice(closeAt - 3, closeAt) === "<!-") {
          insideComment = false;
          closeAt -= 4;
        } else {
          closeAt -= 1;
        }
      } else if (char === ">" && html.slice(closeAt - 2, closeAt) === "--") {
        insideComment = true;
        closeAt -= 3;
      } else if (char === ">") {
        break;
      } else {
        closeAt -= 1;
      }
    }
    afterTag = html.slice(closeAt + 1, html.length);
    const attrsStr = Object.keys(attrs).map((attr) => attrs[attr] === true ? attr : `${attr}="${attrs[attr]}"`).join(" ");
    if (clearInnerHTML) {
      const idAttrStr = id ? ` id="${id}"` : "";
      if (VOID_TAGS.has(tag)) {
        newHTML = `<${tag}${idAttrStr}${attrsStr === "" ? "" : " "}${attrsStr}/>`;
      } else {
        newHTML = `<${tag}${idAttrStr}${attrsStr === "" ? "" : " "}${attrsStr}></${tag}>`;
      }
    } else {
      const rest = html.slice(tagNameEndsAt, closeAt + 1);
      newHTML = `<${tag}${attrsStr === "" ? "" : " "}${attrsStr}${rest}`;
    }
    return [newHTML, beforeTag, afterTag];
  };
  var Rendered = class {
    static extract(diff) {
      const { [REPLY]: reply, [EVENTS]: events, [TITLE]: title } = diff;
      delete diff[REPLY];
      delete diff[EVENTS];
      delete diff[TITLE];
      return { diff, title, reply: reply || null, events: events || [] };
    }
    constructor(viewId, rendered) {
      this.viewId = viewId;
      this.rendered = {};
      this.magicId = 0;
      this.mergeDiff(rendered);
    }
    parentViewId() {
      return this.viewId;
    }
    toString(onlyCids) {
      const { buffer: str, streams } = this.recursiveToString(
        this.rendered,
        this.rendered[COMPONENTS],
        onlyCids,
        true,
        {}
      );
      return { buffer: str, streams };
    }
    recursiveToString(rendered, components = rendered[COMPONENTS], onlyCids, changeTracking, rootAttrs) {
      onlyCids = onlyCids ? new Set(onlyCids) : null;
      const output = {
        buffer: "",
        components,
        onlyCids,
        streams: /* @__PURE__ */ new Set()
      };
      this.toOutputBuffer(rendered, null, output, changeTracking, rootAttrs);
      return { buffer: output.buffer, streams: output.streams };
    }
    componentCIDs(diff) {
      return Object.keys(diff[COMPONENTS] || {}).map((i) => parseInt(i));
    }
    isComponentOnlyDiff(diff) {
      if (!diff[COMPONENTS]) {
        return false;
      }
      return Object.keys(diff).length === 1;
    }
    getComponent(diff, cid) {
      return diff[COMPONENTS][cid];
    }
    resetRender(cid) {
      if (this.rendered[COMPONENTS][cid]) {
        this.rendered[COMPONENTS][cid].reset = true;
      }
    }
    mergeDiff(diff) {
      const newc = diff[COMPONENTS];
      const cache = {};
      delete diff[COMPONENTS];
      this.rendered = this.mutableMerge(this.rendered, diff);
      this.rendered[COMPONENTS] = this.rendered[COMPONENTS] || {};
      if (newc) {
        const oldc = this.rendered[COMPONENTS];
        for (const cid in newc) {
          newc[cid] = this.cachedFindComponent(cid, newc[cid], oldc, newc, cache);
        }
        for (const cid in newc) {
          oldc[cid] = newc[cid];
        }
        diff[COMPONENTS] = newc;
      }
    }
    cachedFindComponent(cid, cdiff, oldc, newc, cache) {
      if (cache[cid]) {
        return cache[cid];
      } else {
        let ndiff, stat, scid = cdiff[STATIC];
        if (isCid(scid)) {
          let tdiff;
          if (scid > 0) {
            tdiff = this.cachedFindComponent(scid, newc[scid], oldc, newc, cache);
          } else {
            tdiff = oldc[-scid];
          }
          stat = tdiff[STATIC];
          ndiff = this.cloneMerge(tdiff, cdiff, true);
          ndiff[STATIC] = stat;
        } else {
          ndiff = cdiff[STATIC] !== void 0 || oldc[cid] === void 0 ? cdiff : this.cloneMerge(oldc[cid], cdiff, false);
        }
        cache[cid] = ndiff;
        return ndiff;
      }
    }
    mutableMerge(target, source) {
      if (source[STATIC] !== void 0) {
        return source;
      } else {
        this.doMutableMerge(target, source);
        return target;
      }
    }
    doMutableMerge(target, source) {
      if (source[KEYED]) {
        this.mergeKeyed(target, source);
      } else {
        for (const key in source) {
          const val = source[key];
          const targetVal = target[key];
          const isObjVal = isObject(val);
          if (isObjVal && val[STATIC] === void 0 && isObject(targetVal)) {
            this.doMutableMerge(targetVal, val);
          } else {
            target[key] = val;
          }
        }
      }
      if (target[ROOT]) {
        target.newRender = true;
      }
    }
    clone(diff) {
      if ("structuredClone" in window) {
        return structuredClone(diff);
      } else {
        return JSON.parse(JSON.stringify(diff));
      }
    }
    // keyed comprehensions
    mergeKeyed(target, source) {
      const clonedTarget = this.clone(target);
      Object.entries(source[KEYED]).forEach(([i, entry]) => {
        if (i === KEYED_COUNT) {
          return;
        }
        if (Array.isArray(entry)) {
          const [old_idx, diff] = entry;
          target[KEYED][i] = clonedTarget[KEYED][old_idx];
          this.doMutableMerge(target[KEYED][i], diff);
        } else if (typeof entry === "number") {
          const old_idx = entry;
          target[KEYED][i] = clonedTarget[KEYED][old_idx];
        } else if (typeof entry === "object") {
          if (!target[KEYED][i]) {
            target[KEYED][i] = {};
          }
          this.doMutableMerge(target[KEYED][i], entry);
        }
      });
      if (source[KEYED][KEYED_COUNT] < target[KEYED][KEYED_COUNT]) {
        for (let i = source[KEYED][KEYED_COUNT]; i < target[KEYED][KEYED_COUNT]; i++) {
          delete target[KEYED][i];
        }
      }
      target[KEYED][KEYED_COUNT] = source[KEYED][KEYED_COUNT];
      if (source[STREAM]) {
        target[STREAM] = source[STREAM];
      }
      if (source[TEMPLATES]) {
        target[TEMPLATES] = source[TEMPLATES];
      }
    }
    // Merges cid trees together, copying statics from source tree.
    //
    // The `pruneMagicId` is passed to control pruning the magicId of the
    // target. We must always prune the magicId when we are sharing statics
    // from another component. If not pruning, we replicate the logic from
    // mutableMerge, where we set newRender to true if there is a root
    // (effectively forcing the new version to be rendered instead of skipped)
    //
    cloneMerge(target, source, pruneMagicId) {
      let merged;
      if (source[KEYED]) {
        merged = this.clone(target);
        this.mergeKeyed(merged, source);
      } else {
        merged = { ...target, ...source };
        for (const key in merged) {
          const val = source[key];
          const targetVal = target[key];
          if (isObject(val) && val[STATIC] === void 0 && isObject(targetVal)) {
            merged[key] = this.cloneMerge(targetVal, val, pruneMagicId);
          } else if (val === void 0 && isObject(targetVal)) {
            merged[key] = this.cloneMerge(targetVal, {}, pruneMagicId);
          }
        }
      }
      if (pruneMagicId) {
        delete merged.magicId;
        delete merged.newRender;
      } else if (target[ROOT]) {
        merged.newRender = true;
      }
      return merged;
    }
    componentToString(cid) {
      const { buffer: str, streams } = this.recursiveCIDToString(
        this.rendered[COMPONENTS],
        cid,
        null
      );
      const [strippedHTML, _before, _after] = modifyRoot(str, {});
      return { buffer: strippedHTML, streams };
    }
    pruneCIDs(cids) {
      cids.forEach((cid) => delete this.rendered[COMPONENTS][cid]);
    }
    // private
    get() {
      return this.rendered;
    }
    isNewFingerprint(diff = {}) {
      return !!diff[STATIC];
    }
    templateStatic(part, templates) {
      if (typeof part === "number") {
        return templates[part];
      } else {
        return part;
      }
    }
    nextMagicID() {
      this.magicId++;
      return `m${this.magicId}-${this.parentViewId()}`;
    }
    // Converts rendered tree to output buffer.
    //
    // changeTracking controls if we can apply the PHX_SKIP optimization.
    toOutputBuffer(rendered, templates, output, changeTracking, rootAttrs = {}) {
      if (rendered[KEYED]) {
        return this.comprehensionToBuffer(
          rendered,
          templates,
          output,
          changeTracking
        );
      }
      if (rendered[TEMPLATES]) {
        templates = rendered[TEMPLATES];
        delete rendered[TEMPLATES];
      }
      let { [STATIC]: statics } = rendered;
      statics = this.templateStatic(statics, templates);
      rendered[STATIC] = statics;
      const isRoot = rendered[ROOT];
      const prevBuffer = output.buffer;
      if (isRoot) {
        output.buffer = "";
      }
      if (changeTracking && isRoot && !rendered.magicId) {
        rendered.newRender = true;
        rendered.magicId = this.nextMagicID();
      }
      output.buffer += statics[0];
      for (let i = 1; i < statics.length; i++) {
        this.dynamicToBuffer(rendered[i - 1], templates, output, changeTracking);
        output.buffer += statics[i];
      }
      if (isRoot) {
        let skip = false;
        let attrs;
        if (changeTracking || rendered.magicId) {
          skip = changeTracking && !rendered.newRender;
          attrs = { [PHX_MAGIC_ID]: rendered.magicId, ...rootAttrs };
        } else {
          attrs = rootAttrs;
        }
        if (skip) {
          attrs[PHX_SKIP] = true;
        }
        const [newRoot, commentBefore, commentAfter] = modifyRoot(
          output.buffer,
          attrs,
          skip
        );
        rendered.newRender = false;
        output.buffer = prevBuffer + commentBefore + newRoot + commentAfter;
      }
    }
    comprehensionToBuffer(rendered, templates, output, changeTracking) {
      const keyedTemplates = templates || rendered[TEMPLATES];
      const statics = this.templateStatic(rendered[STATIC], templates);
      rendered[STATIC] = statics;
      delete rendered[TEMPLATES];
      for (let i = 0; i < rendered[KEYED][KEYED_COUNT]; i++) {
        output.buffer += statics[0];
        for (let j = 1; j < statics.length; j++) {
          this.dynamicToBuffer(
            rendered[KEYED][i][j - 1],
            keyedTemplates,
            output,
            changeTracking
          );
          output.buffer += statics[j];
        }
      }
      if (rendered[STREAM]) {
        const stream = rendered[STREAM];
        const [_ref, _inserts, deleteIds, reset] = stream || [null, {}, [], null];
        if (stream !== void 0 && (rendered[KEYED][KEYED_COUNT] > 0 || deleteIds.length > 0 || reset)) {
          delete rendered[STREAM];
          rendered[KEYED] = {
            [KEYED_COUNT]: 0
          };
          output.streams.add(stream);
        }
      }
    }
    dynamicToBuffer(rendered, templates, output, changeTracking) {
      if (typeof rendered === "number") {
        const { buffer: str, streams } = this.recursiveCIDToString(
          output.components,
          rendered,
          output.onlyCids
        );
        output.buffer += str;
        output.streams = /* @__PURE__ */ new Set([...output.streams, ...streams]);
      } else if (isObject(rendered)) {
        this.toOutputBuffer(rendered, templates, output, changeTracking, {});
      } else {
        output.buffer += rendered;
      }
    }
    recursiveCIDToString(components, cid, onlyCids) {
      const component = components[cid] || logError(`no component for CID ${cid}`, components);
      const attrs = { [PHX_COMPONENT]: cid, [PHX_VIEW_REF]: this.viewId };
      const skip = onlyCids && !onlyCids.has(cid);
      component.newRender = !skip;
      component.magicId = `c${cid}-${this.parentViewId()}`;
      const changeTracking = !component.reset;
      const { buffer: html, streams } = this.recursiveToString(
        component,
        components,
        onlyCids,
        changeTracking,
        attrs
      );
      delete component.reset;
      return { buffer: html, streams };
    }
  };
  var focusStack = [];
  var default_transition_time = 200;
  var JS = {
    // private
    exec(e, eventType, phxEvent, view, sourceEl, defaults) {
      const [defaultKind, defaultArgs] = defaults || [
        null,
        { callback: defaults && defaults.callback }
      ];
      const commands = phxEvent.charAt(0) === "[" ? JSON.parse(phxEvent) : [[defaultKind, defaultArgs]];
      commands.forEach(([kind, args]) => {
        if (kind === defaultKind) {
          args = { ...defaultArgs, ...args };
          args.callback = args.callback || defaultArgs.callback;
        }
        this.filterToEls(view.liveSocket, sourceEl, args).forEach((el) => {
          this[`exec_${kind}`](e, eventType, phxEvent, view, sourceEl, el, args);
        });
      });
    },
    isVisible(el) {
      return !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length > 0);
    },
    // returns true if any part of the element is inside the viewport
    isInViewport(el) {
      const rect = el.getBoundingClientRect();
      const windowHeight = window.innerHeight || document.documentElement.clientHeight;
      const windowWidth = window.innerWidth || document.documentElement.clientWidth;
      return rect.right > 0 && rect.bottom > 0 && rect.left < windowWidth && rect.top < windowHeight;
    },
    // private
    // commands
    exec_exec(e, eventType, phxEvent, view, sourceEl, el, { attr, to }) {
      const encodedJS = el.getAttribute(attr);
      if (!encodedJS) {
        throw new Error(`expected ${attr} to contain JS command on "${to}"`);
      }
      view.liveSocket.execJS(el, encodedJS, eventType);
    },
    exec_dispatch(e, eventType, phxEvent, view, sourceEl, el, { event, detail, bubbles, blocking }) {
      detail = detail || {};
      detail.dispatcher = sourceEl;
      if (blocking) {
        const promise = new Promise((resolve, _reject) => {
          detail.done = resolve;
        });
        view.liveSocket.asyncTransition(promise);
      }
      dom_default.dispatchEvent(el, event, { detail, bubbles });
    },
    exec_push(e, eventType, phxEvent, view, sourceEl, el, args) {
      const {
        event,
        data,
        target,
        page_loading,
        loading,
        value,
        dispatcher,
        callback
      } = args;
      const pushOpts = {
        loading,
        value,
        target,
        page_loading: !!page_loading,
        originalEvent: e
      };
      const targetSrc = eventType === "change" && dispatcher ? dispatcher : sourceEl;
      const phxTarget = target || targetSrc.getAttribute(view.binding("target")) || targetSrc;
      const handler = (targetView, targetCtx) => {
        if (!targetView.isConnected()) {
          return;
        }
        if (eventType === "change") {
          let { newCid, _target } = args;
          _target = _target || (dom_default.isFormInput(sourceEl) ? sourceEl.name : void 0);
          if (_target) {
            pushOpts._target = _target;
          }
          targetView.pushInput(
            sourceEl,
            targetCtx,
            newCid,
            event || phxEvent,
            pushOpts,
            callback
          );
        } else if (eventType === "submit") {
          const { submitter } = args;
          targetView.submitForm(
            sourceEl,
            targetCtx,
            event || phxEvent,
            submitter,
            pushOpts,
            callback
          );
        } else {
          targetView.pushEvent(
            eventType,
            sourceEl,
            targetCtx,
            event || phxEvent,
            data,
            pushOpts,
            callback
          );
        }
      };
      if (args.targetView && args.targetCtx) {
        handler(args.targetView, args.targetCtx);
      } else {
        view.withinTargets(phxTarget, handler);
      }
    },
    exec_navigate(e, eventType, phxEvent, view, sourceEl, el, { href, replace }) {
      view.liveSocket.historyRedirect(
        e,
        href,
        replace ? "replace" : "push",
        null,
        sourceEl
      );
    },
    exec_patch(e, eventType, phxEvent, view, sourceEl, el, { href, replace }) {
      view.liveSocket.pushHistoryPatch(
        e,
        href,
        replace ? "replace" : "push",
        sourceEl
      );
    },
    exec_focus(e, eventType, phxEvent, view, sourceEl, el) {
      aria_default.attemptFocus(el);
      window.requestAnimationFrame(() => {
        window.requestAnimationFrame(() => aria_default.attemptFocus(el));
      });
    },
    exec_focus_first(e, eventType, phxEvent, view, sourceEl, el) {
      aria_default.focusFirstInteractive(el) || aria_default.focusFirst(el);
      window.requestAnimationFrame(() => {
        window.requestAnimationFrame(
          () => aria_default.focusFirstInteractive(el) || aria_default.focusFirst(el)
        );
      });
    },
    exec_push_focus(e, eventType, phxEvent, view, sourceEl, el) {
      focusStack.push(el || sourceEl);
    },
    exec_pop_focus(_e, _eventType, _phxEvent, _view, _sourceEl, _el) {
      const el = focusStack.pop();
      if (el) {
        el.focus();
        window.requestAnimationFrame(() => {
          window.requestAnimationFrame(() => el.focus());
        });
      }
    },
    exec_add_class(e, eventType, phxEvent, view, sourceEl, el, { names, transition, time, blocking }) {
      this.addOrRemoveClasses(el, names, [], transition, time, view, blocking);
    },
    exec_remove_class(e, eventType, phxEvent, view, sourceEl, el, { names, transition, time, blocking }) {
      this.addOrRemoveClasses(el, [], names, transition, time, view, blocking);
    },
    exec_toggle_class(e, eventType, phxEvent, view, sourceEl, el, { names, transition, time, blocking }) {
      this.toggleClasses(el, names, transition, time, view, blocking);
    },
    exec_toggle_attr(e, eventType, phxEvent, view, sourceEl, el, { attr: [attr, val1, val2] }) {
      this.toggleAttr(el, attr, val1, val2);
    },
    exec_ignore_attrs(e, eventType, phxEvent, view, sourceEl, el, { attrs }) {
      this.ignoreAttrs(el, attrs);
    },
    exec_transition(e, eventType, phxEvent, view, sourceEl, el, { time, transition, blocking }) {
      this.addOrRemoveClasses(el, [], [], transition, time, view, blocking);
    },
    exec_toggle(e, eventType, phxEvent, view, sourceEl, el, { display, ins, outs, time, blocking }) {
      this.toggle(eventType, view, el, display, ins, outs, time, blocking);
    },
    exec_show(e, eventType, phxEvent, view, sourceEl, el, { display, transition, time, blocking }) {
      this.show(eventType, view, el, display, transition, time, blocking);
    },
    exec_hide(e, eventType, phxEvent, view, sourceEl, el, { display, transition, time, blocking }) {
      this.hide(eventType, view, el, display, transition, time, blocking);
    },
    exec_set_attr(e, eventType, phxEvent, view, sourceEl, el, { attr: [attr, val] }) {
      this.setOrRemoveAttrs(el, [[attr, val]], []);
    },
    exec_remove_attr(e, eventType, phxEvent, view, sourceEl, el, { attr }) {
      this.setOrRemoveAttrs(el, [], [attr]);
    },
    ignoreAttrs(el, attrs) {
      dom_default.putPrivate(el, "JS:ignore_attrs", {
        apply: (fromEl, toEl) => {
          let fromAttributes = Array.from(fromEl.attributes);
          let fromAttributeNames = fromAttributes.map((attr) => attr.name);
          Array.from(toEl.attributes).filter((attr) => {
            return !fromAttributeNames.includes(attr.name);
          }).forEach((attr) => {
            if (dom_default.attributeIgnored(attr, attrs)) {
              toEl.removeAttribute(attr.name);
            }
          });
          fromAttributes.forEach((attr) => {
            if (dom_default.attributeIgnored(attr, attrs)) {
              toEl.setAttribute(attr.name, attr.value);
            }
          });
        }
      });
    },
    onBeforeElUpdated(fromEl, toEl) {
      const ignoreAttrs = dom_default.private(fromEl, "JS:ignore_attrs");
      if (ignoreAttrs) {
        ignoreAttrs.apply(fromEl, toEl);
      }
    },
    // utils for commands
    show(eventType, view, el, display, transition, time, blocking) {
      if (!this.isVisible(el)) {
        this.toggle(
          eventType,
          view,
          el,
          display,
          transition,
          null,
          time,
          blocking
        );
      }
    },
    hide(eventType, view, el, display, transition, time, blocking) {
      if (this.isVisible(el)) {
        this.toggle(
          eventType,
          view,
          el,
          display,
          null,
          transition,
          time,
          blocking
        );
      }
    },
    toggle(eventType, view, el, display, ins, outs, time, blocking) {
      time = time || default_transition_time;
      const [inClasses, inStartClasses, inEndClasses] = ins || [[], [], []];
      const [outClasses, outStartClasses, outEndClasses] = outs || [[], [], []];
      if (inClasses.length > 0 || outClasses.length > 0) {
        if (this.isVisible(el)) {
          const onStart = () => {
            this.addOrRemoveClasses(
              el,
              outStartClasses,
              inClasses.concat(inStartClasses).concat(inEndClasses)
            );
            window.requestAnimationFrame(() => {
              this.addOrRemoveClasses(el, outClasses, []);
              window.requestAnimationFrame(
                () => this.addOrRemoveClasses(el, outEndClasses, outStartClasses)
              );
            });
          };
          const onEnd = () => {
            this.addOrRemoveClasses(el, [], outClasses.concat(outEndClasses));
            dom_default.putSticky(
              el,
              "toggle",
              (currentEl) => currentEl.style.display = "none"
            );
            el.dispatchEvent(new Event("phx:hide-end"));
          };
          el.dispatchEvent(new Event("phx:hide-start"));
          if (blocking === false) {
            onStart();
            setTimeout(onEnd, time);
          } else {
            view.transition(time, onStart, onEnd);
          }
        } else {
          if (eventType === "remove") {
            return;
          }
          const onStart = () => {
            this.addOrRemoveClasses(
              el,
              inStartClasses,
              outClasses.concat(outStartClasses).concat(outEndClasses)
            );
            const stickyDisplay = display || this.defaultDisplay(el);
            window.requestAnimationFrame(() => {
              this.addOrRemoveClasses(el, inClasses, []);
              window.requestAnimationFrame(() => {
                dom_default.putSticky(
                  el,
                  "toggle",
                  (currentEl) => currentEl.style.display = stickyDisplay
                );
                this.addOrRemoveClasses(el, inEndClasses, inStartClasses);
              });
            });
          };
          const onEnd = () => {
            this.addOrRemoveClasses(el, [], inClasses.concat(inEndClasses));
            el.dispatchEvent(new Event("phx:show-end"));
          };
          el.dispatchEvent(new Event("phx:show-start"));
          if (blocking === false) {
            onStart();
            setTimeout(onEnd, time);
          } else {
            view.transition(time, onStart, onEnd);
          }
        }
      } else {
        if (this.isVisible(el)) {
          window.requestAnimationFrame(() => {
            el.dispatchEvent(new Event("phx:hide-start"));
            dom_default.putSticky(
              el,
              "toggle",
              (currentEl) => currentEl.style.display = "none"
            );
            el.dispatchEvent(new Event("phx:hide-end"));
          });
        } else {
          window.requestAnimationFrame(() => {
            el.dispatchEvent(new Event("phx:show-start"));
            const stickyDisplay = display || this.defaultDisplay(el);
            dom_default.putSticky(
              el,
              "toggle",
              (currentEl) => currentEl.style.display = stickyDisplay
            );
            el.dispatchEvent(new Event("phx:show-end"));
          });
        }
      }
    },
    toggleClasses(el, classes, transition, time, view, blocking) {
      window.requestAnimationFrame(() => {
        const [prevAdds, prevRemoves] = dom_default.getSticky(el, "classes", [[], []]);
        const newAdds = classes.filter(
          (name) => prevAdds.indexOf(name) < 0 && !el.classList.contains(name)
        );
        const newRemoves = classes.filter(
          (name) => prevRemoves.indexOf(name) < 0 && el.classList.contains(name)
        );
        this.addOrRemoveClasses(
          el,
          newAdds,
          newRemoves,
          transition,
          time,
          view,
          blocking
        );
      });
    },
    toggleAttr(el, attr, val1, val2) {
      if (el.hasAttribute(attr)) {
        if (val2 !== void 0) {
          if (el.getAttribute(attr) === val1) {
            this.setOrRemoveAttrs(el, [[attr, val2]], []);
          } else {
            this.setOrRemoveAttrs(el, [[attr, val1]], []);
          }
        } else {
          this.setOrRemoveAttrs(el, [], [attr]);
        }
      } else {
        this.setOrRemoveAttrs(el, [[attr, val1]], []);
      }
    },
    addOrRemoveClasses(el, adds, removes, transition, time, view, blocking) {
      time = time || default_transition_time;
      const [transitionRun, transitionStart, transitionEnd] = transition || [
        [],
        [],
        []
      ];
      if (transitionRun.length > 0) {
        const onStart = () => {
          this.addOrRemoveClasses(
            el,
            transitionStart,
            [].concat(transitionRun).concat(transitionEnd)
          );
          window.requestAnimationFrame(() => {
            this.addOrRemoveClasses(el, transitionRun, []);
            window.requestAnimationFrame(
              () => this.addOrRemoveClasses(el, transitionEnd, transitionStart)
            );
          });
        };
        const onDone = () => this.addOrRemoveClasses(
          el,
          adds.concat(transitionEnd),
          removes.concat(transitionRun).concat(transitionStart)
        );
        if (blocking === false) {
          onStart();
          setTimeout(onDone, time);
        } else {
          view.transition(time, onStart, onDone);
        }
        return;
      }
      window.requestAnimationFrame(() => {
        const [prevAdds, prevRemoves] = dom_default.getSticky(el, "classes", [[], []]);
        const keepAdds = adds.filter(
          (name) => prevAdds.indexOf(name) < 0 && !el.classList.contains(name)
        );
        const keepRemoves = removes.filter(
          (name) => prevRemoves.indexOf(name) < 0 && el.classList.contains(name)
        );
        const newAdds = prevAdds.filter((name) => removes.indexOf(name) < 0).concat(keepAdds);
        const newRemoves = prevRemoves.filter((name) => adds.indexOf(name) < 0).concat(keepRemoves);
        dom_default.putSticky(el, "classes", (currentEl) => {
          currentEl.classList.remove(...newRemoves);
          currentEl.classList.add(...newAdds);
          return [newAdds, newRemoves];
        });
      });
    },
    setOrRemoveAttrs(el, sets, removes) {
      const [prevSets, prevRemoves] = dom_default.getSticky(el, "attrs", [[], []]);
      const alteredAttrs = sets.map(([attr, _val]) => attr).concat(removes);
      const newSets = prevSets.filter(([attr, _val]) => !alteredAttrs.includes(attr)).concat(sets);
      const newRemoves = prevRemoves.filter((attr) => !alteredAttrs.includes(attr)).concat(removes);
      dom_default.putSticky(el, "attrs", (currentEl) => {
        newRemoves.forEach((attr) => currentEl.removeAttribute(attr));
        newSets.forEach(([attr, val]) => currentEl.setAttribute(attr, val));
        return [newSets, newRemoves];
      });
    },
    hasAllClasses(el, classes) {
      return classes.every((name) => el.classList.contains(name));
    },
    isToggledOut(el, outClasses) {
      return !this.isVisible(el) || this.hasAllClasses(el, outClasses);
    },
    filterToEls(liveSocket2, sourceEl, { to }) {
      const defaultQuery = () => {
        if (typeof to === "string") {
          return document.querySelectorAll(to);
        } else if (to.closest) {
          const toEl = sourceEl.closest(to.closest);
          return toEl ? [toEl] : [];
        } else if (to.inner) {
          return sourceEl.querySelectorAll(to.inner);
        }
      };
      return to ? liveSocket2.jsQuerySelectorAll(sourceEl, to, defaultQuery) : [sourceEl];
    },
    defaultDisplay(el) {
      return { tr: "table-row", td: "table-cell" }[el.tagName.toLowerCase()] || "block";
    },
    transitionClasses(val) {
      if (!val) {
        return null;
      }
      let [trans, tStart, tEnd] = Array.isArray(val) ? val : [val.split(" "), [], []];
      trans = Array.isArray(trans) ? trans : trans.split(" ");
      tStart = Array.isArray(tStart) ? tStart : tStart.split(" ");
      tEnd = Array.isArray(tEnd) ? tEnd : tEnd.split(" ");
      return [trans, tStart, tEnd];
    }
  };
  var js_default = JS;
  var js_commands_default = (liveSocket2, eventType) => {
    return {
      exec(el, encodedJS) {
        liveSocket2.execJS(el, encodedJS, eventType);
      },
      show(el, opts = {}) {
        const owner = liveSocket2.owner(el);
        js_default.show(
          eventType,
          owner,
          el,
          opts.display,
          js_default.transitionClasses(opts.transition),
          opts.time,
          opts.blocking
        );
      },
      hide(el, opts = {}) {
        const owner = liveSocket2.owner(el);
        js_default.hide(
          eventType,
          owner,
          el,
          null,
          js_default.transitionClasses(opts.transition),
          opts.time,
          opts.blocking
        );
      },
      toggle(el, opts = {}) {
        const owner = liveSocket2.owner(el);
        const inTransition = js_default.transitionClasses(opts.in);
        const outTransition = js_default.transitionClasses(opts.out);
        js_default.toggle(
          eventType,
          owner,
          el,
          opts.display,
          inTransition,
          outTransition,
          opts.time,
          opts.blocking
        );
      },
      addClass(el, names, opts = {}) {
        const classNames = Array.isArray(names) ? names : names.split(" ");
        const owner = liveSocket2.owner(el);
        js_default.addOrRemoveClasses(
          el,
          classNames,
          [],
          js_default.transitionClasses(opts.transition),
          opts.time,
          owner,
          opts.blocking
        );
      },
      removeClass(el, names, opts = {}) {
        const classNames = Array.isArray(names) ? names : names.split(" ");
        const owner = liveSocket2.owner(el);
        js_default.addOrRemoveClasses(
          el,
          [],
          classNames,
          js_default.transitionClasses(opts.transition),
          opts.time,
          owner,
          opts.blocking
        );
      },
      toggleClass(el, names, opts = {}) {
        const classNames = Array.isArray(names) ? names : names.split(" ");
        const owner = liveSocket2.owner(el);
        js_default.toggleClasses(
          el,
          classNames,
          js_default.transitionClasses(opts.transition),
          opts.time,
          owner,
          opts.blocking
        );
      },
      transition(el, transition, opts = {}) {
        const owner = liveSocket2.owner(el);
        js_default.addOrRemoveClasses(
          el,
          [],
          [],
          js_default.transitionClasses(transition),
          opts.time,
          owner,
          opts.blocking
        );
      },
      setAttribute(el, attr, val) {
        js_default.setOrRemoveAttrs(el, [[attr, val]], []);
      },
      removeAttribute(el, attr) {
        js_default.setOrRemoveAttrs(el, [], [attr]);
      },
      toggleAttribute(el, attr, val1, val2) {
        js_default.toggleAttr(el, attr, val1, val2);
      },
      push(el, type, opts = {}) {
        liveSocket2.withinOwners(el, (view) => {
          const data = opts.value || {};
          delete opts.value;
          let e = new CustomEvent("phx:exec", { detail: { sourceElement: el } });
          js_default.exec(e, eventType, type, view, el, ["push", { data, ...opts }]);
        });
      },
      navigate(href, opts = {}) {
        const customEvent = new CustomEvent("phx:exec");
        liveSocket2.historyRedirect(
          customEvent,
          href,
          opts.replace ? "replace" : "push",
          null,
          null
        );
      },
      patch(href, opts = {}) {
        const customEvent = new CustomEvent("phx:exec");
        liveSocket2.pushHistoryPatch(
          customEvent,
          href,
          opts.replace ? "replace" : "push",
          null
        );
      },
      ignoreAttributes(el, attrs) {
        js_default.ignoreAttrs(el, Array.isArray(attrs) ? attrs : [attrs]);
      }
    };
  };
  var HOOK_ID = "hookId";
  var viewHookID = 1;
  var ViewHook = class _ViewHook {
    get liveSocket() {
      return this.__liveSocket();
    }
    static makeID() {
      return viewHookID++;
    }
    static elementID(el) {
      return dom_default.private(el, HOOK_ID);
    }
    constructor(view, el, callbacks) {
      this.el = el;
      this.__attachView(view);
      this.__listeners = /* @__PURE__ */ new Set();
      this.__isDisconnected = false;
      dom_default.putPrivate(this.el, HOOK_ID, _ViewHook.makeID());
      if (callbacks) {
        const protectedProps = /* @__PURE__ */ new Set([
          "el",
          "liveSocket",
          "__view",
          "__listeners",
          "__isDisconnected",
          "constructor",
          // Standard object properties
          // Core ViewHook API methods
          "js",
          "pushEvent",
          "pushEventTo",
          "handleEvent",
          "removeHandleEvent",
          "upload",
          "uploadTo",
          // Internal lifecycle callers
          "__mounted",
          "__updated",
          "__beforeUpdate",
          "__destroyed",
          "__reconnected",
          "__disconnected",
          "__cleanup__"
        ]);
        for (const key in callbacks) {
          if (Object.prototype.hasOwnProperty.call(callbacks, key)) {
            this[key] = callbacks[key];
            if (protectedProps.has(key)) {
              console.warn(
                `Hook object for element #${el.id} overwrites core property '${key}'!`
              );
            }
          }
        }
        const lifecycleMethods = [
          "mounted",
          "beforeUpdate",
          "updated",
          "destroyed",
          "disconnected",
          "reconnected"
        ];
        lifecycleMethods.forEach((methodName) => {
          if (callbacks[methodName] && typeof callbacks[methodName] === "function") {
            this[methodName] = callbacks[methodName];
          }
        });
      }
    }
    /** @internal */
    __attachView(view) {
      if (view) {
        this.__view = () => view;
        this.__liveSocket = () => view.liveSocket;
      } else {
        this.__view = () => {
          throw new Error(
            `hook not yet attached to a live view: ${this.el.outerHTML}`
          );
        };
        this.__liveSocket = () => {
          throw new Error(
            `hook not yet attached to a live view: ${this.el.outerHTML}`
          );
        };
      }
    }
    // Default lifecycle methods
    mounted() {
    }
    beforeUpdate() {
    }
    updated() {
    }
    destroyed() {
    }
    disconnected() {
    }
    reconnected() {
    }
    // Internal lifecycle callers - called by the View
    /** @internal */
    __mounted() {
      this.mounted();
    }
    /** @internal */
    __updated() {
      this.updated();
    }
    /** @internal */
    __beforeUpdate() {
      this.beforeUpdate();
    }
    /** @internal */
    __destroyed() {
      this.destroyed();
      dom_default.deletePrivate(this.el, HOOK_ID);
    }
    /** @internal */
    __reconnected() {
      if (this.__isDisconnected) {
        this.__isDisconnected = false;
        this.reconnected();
      }
    }
    /** @internal */
    __disconnected() {
      this.__isDisconnected = true;
      this.disconnected();
    }
    js() {
      return {
        ...js_commands_default(this.__view().liveSocket, "hook"),
        exec: (encodedJS) => {
          this.__view().liveSocket.execJS(this.el, encodedJS, "hook");
        }
      };
    }
    pushEvent(event, payload, onReply) {
      const promise = this.__view().pushHookEvent(
        this.el,
        null,
        event,
        payload || {}
      );
      if (onReply === void 0) {
        return promise.then(({ reply }) => reply);
      }
      promise.then(
        ({ reply, ref }) => onReply(reply, ref)
      ).catch(() => {
      });
    }
    pushEventTo(selectorOrTarget, event, payload, onReply) {
      if (onReply === void 0) {
        const targetPair = [];
        this.__view().withinTargets(
          selectorOrTarget,
          (view, targetCtx) => {
            targetPair.push({ view, targetCtx });
          }
        );
        const promises = targetPair.map(({ view, targetCtx }) => {
          return view.pushHookEvent(this.el, targetCtx, event, payload || {});
        });
        return Promise.allSettled(promises);
      }
      this.__view().withinTargets(
        selectorOrTarget,
        (view, targetCtx) => {
          view.pushHookEvent(this.el, targetCtx, event, payload || {}).then(
            ({ reply, ref }) => onReply(reply, ref)
          ).catch(() => {
          });
        }
      );
    }
    handleEvent(event, callback) {
      const callbackRef = {
        event,
        callback: (customEvent) => callback(customEvent.detail)
      };
      window.addEventListener(
        `phx:${event}`,
        callbackRef.callback
      );
      this.__listeners.add(callbackRef);
      return callbackRef;
    }
    removeHandleEvent(ref) {
      window.removeEventListener(
        `phx:${ref.event}`,
        ref.callback
      );
      this.__listeners.delete(ref);
    }
    upload(name, files) {
      return this.__view().dispatchUploads(null, name, files);
    }
    uploadTo(selectorOrTarget, name, files) {
      return this.__view().withinTargets(
        selectorOrTarget,
        (view, targetCtx) => {
          view.dispatchUploads(targetCtx, name, files);
        }
      );
    }
    /** @internal */
    __cleanup__() {
      this.__listeners.forEach(
        (callbackRef) => this.removeHandleEvent(callbackRef)
      );
    }
  };
  var prependFormDataKey = (key, prefix) => {
    const isArray = key.endsWith("[]");
    let baseKey = isArray ? key.slice(0, -2) : key;
    baseKey = baseKey.replace(/([^\[\]]+)(\]?$)/, `${prefix}$1$2`);
    if (isArray) {
      baseKey += "[]";
    }
    return baseKey;
  };
  var serializeForm = (form, opts, onlyNames = []) => {
    const { submitter } = opts;
    let injectedElement;
    if (submitter && submitter.name) {
      const input = document.createElement("input");
      input.type = "hidden";
      const formId = submitter.getAttribute("form");
      if (formId) {
        input.setAttribute("form", formId);
      }
      input.name = submitter.name;
      input.value = submitter.value;
      submitter.parentElement.insertBefore(input, submitter);
      injectedElement = input;
    }
    const formData = new FormData(form);
    const toRemove = [];
    formData.forEach((val, key, _index) => {
      if (val instanceof File) {
        toRemove.push(key);
      }
    });
    toRemove.forEach((key) => formData.delete(key));
    const params = new URLSearchParams();
    const { inputsUnused, onlyHiddenInputs } = Array.from(form.elements).reduce(
      (acc, input) => {
        const { inputsUnused: inputsUnused2, onlyHiddenInputs: onlyHiddenInputs2 } = acc;
        const key = input.name;
        if (!key) {
          return acc;
        }
        if (inputsUnused2[key] === void 0) {
          inputsUnused2[key] = true;
        }
        if (onlyHiddenInputs2[key] === void 0) {
          onlyHiddenInputs2[key] = true;
        }
        const isUsed = dom_default.private(input, PHX_HAS_FOCUSED) || dom_default.private(input, PHX_HAS_SUBMITTED);
        const isHidden = input.type === "hidden";
        inputsUnused2[key] = inputsUnused2[key] && !isUsed;
        onlyHiddenInputs2[key] = onlyHiddenInputs2[key] && isHidden;
        return acc;
      },
      { inputsUnused: {}, onlyHiddenInputs: {} }
    );
    for (const [key, val] of formData.entries()) {
      if (onlyNames.length === 0 || onlyNames.indexOf(key) >= 0) {
        const isUnused = inputsUnused[key];
        const hidden = onlyHiddenInputs[key];
        if (isUnused && !(submitter && submitter.name == key) && !hidden) {
          params.append(prependFormDataKey(key, "_unused_"), "");
        }
        if (typeof val === "string") {
          params.append(key, val);
        }
      }
    }
    if (submitter && injectedElement) {
      submitter.parentElement.removeChild(injectedElement);
    }
    return params.toString();
  };
  var View = class _View {
    static closestView(el) {
      const liveViewEl = el.closest(PHX_VIEW_SELECTOR);
      return liveViewEl ? dom_default.private(liveViewEl, "view") : null;
    }
    constructor(el, liveSocket2, parentView, flash, liveReferer) {
      this.isDead = false;
      this.liveSocket = liveSocket2;
      this.flash = flash;
      this.parent = parentView;
      this.root = parentView ? parentView.root : this;
      this.el = el;
      const boundView = dom_default.private(this.el, "view");
      if (boundView !== void 0 && boundView.isDead !== true) {
        logError(
          `The DOM element for this view has already been bound to a view.

        An element can only ever be associated with a single view!
        Please ensure that you are not trying to initialize multiple LiveSockets on the same page.
        This could happen if you're accidentally trying to render your root layout more than once.
        Ensure that the template set on the LiveView is different than the root layout.
      `,
          { view: boundView }
        );
        throw new Error("Cannot bind multiple views to the same DOM element.");
      }
      dom_default.putPrivate(this.el, "view", this);
      this.id = this.el.id;
      this.ref = 0;
      this.lastAckRef = null;
      this.childJoins = 0;
      this.loaderTimer = null;
      this.disconnectedTimer = null;
      this.pendingDiffs = [];
      this.pendingForms = /* @__PURE__ */ new Set();
      this.redirect = false;
      this.href = null;
      this.joinCount = this.parent ? this.parent.joinCount - 1 : 0;
      this.joinAttempts = 0;
      this.joinPending = true;
      this.destroyed = false;
      this.joinCallback = function(onDone) {
        onDone && onDone();
      };
      this.stopCallback = function() {
      };
      this.pendingJoinOps = [];
      this.viewHooks = {};
      this.formSubmits = [];
      this.children = this.parent ? null : {};
      this.root.children[this.id] = {};
      this.formsForRecovery = {};
      this.channel = this.liveSocket.channel(`lv:${this.id}`, () => {
        const url = this.href && this.expandURL(this.href);
        return {
          redirect: this.redirect ? url : void 0,
          url: this.redirect ? void 0 : url || void 0,
          params: this.connectParams(liveReferer),
          session: this.getSession(),
          static: this.getStatic(),
          flash: this.flash,
          sticky: this.el.hasAttribute(PHX_STICKY)
        };
      });
      this.portalElementIds = /* @__PURE__ */ new Set();
    }
    setHref(href) {
      this.href = href;
    }
    setRedirect(href) {
      this.redirect = true;
      this.href = href;
    }
    isMain() {
      return this.el.hasAttribute(PHX_MAIN);
    }
    connectParams(liveReferer) {
      const params = this.liveSocket.params(this.el);
      const manifest = dom_default.all(document, `[${this.binding(PHX_TRACK_STATIC)}]`).map((node) => node.src || node.href).filter((url) => typeof url === "string");
      if (manifest.length > 0) {
        params["_track_static"] = manifest;
      }
      params["_mounts"] = this.joinCount;
      params["_mount_attempts"] = this.joinAttempts;
      params["_live_referer"] = liveReferer;
      this.joinAttempts++;
      return params;
    }
    isConnected() {
      return this.channel.canPush();
    }
    getSession() {
      return this.el.getAttribute(PHX_SESSION);
    }
    getStatic() {
      const val = this.el.getAttribute(PHX_STATIC);
      return val === "" ? null : val;
    }
    destroy(callback = function() {
    }) {
      this.destroyAllChildren();
      this.destroyPortalElements();
      this.destroyed = true;
      dom_default.deletePrivate(this.el, "view");
      delete this.root.children[this.id];
      if (this.parent) {
        delete this.root.children[this.parent.id][this.id];
      }
      clearTimeout(this.loaderTimer);
      const onFinished = () => {
        callback();
        for (const id in this.viewHooks) {
          this.destroyHook(this.viewHooks[id]);
        }
      };
      dom_default.markPhxChildDestroyed(this.el);
      this.log("destroyed", () => ["the child has been removed from the parent"]);
      this.channel.leave().receive("ok", onFinished).receive("error", onFinished).receive("timeout", onFinished);
    }
    setContainerClasses(...classes) {
      this.el.classList.remove(
        PHX_CONNECTED_CLASS,
        PHX_LOADING_CLASS,
        PHX_ERROR_CLASS,
        PHX_CLIENT_ERROR_CLASS,
        PHX_SERVER_ERROR_CLASS
      );
      this.el.classList.add(...classes);
    }
    showLoader(timeout) {
      clearTimeout(this.loaderTimer);
      if (timeout) {
        this.loaderTimer = setTimeout(() => this.showLoader(), timeout);
      } else {
        for (const id in this.viewHooks) {
          this.viewHooks[id].__disconnected();
        }
        this.setContainerClasses(PHX_LOADING_CLASS);
      }
    }
    execAll(binding) {
      dom_default.all(
        this.el,
        `[${binding}]`,
        (el) => this.liveSocket.execJS(el, el.getAttribute(binding))
      );
    }
    hideLoader() {
      clearTimeout(this.loaderTimer);
      clearTimeout(this.disconnectedTimer);
      this.setContainerClasses(PHX_CONNECTED_CLASS);
      this.execAll(this.binding("connected"));
    }
    triggerReconnected() {
      for (const id in this.viewHooks) {
        this.viewHooks[id].__reconnected();
      }
    }
    log(kind, msgCallback) {
      this.liveSocket.log(this, kind, msgCallback);
    }
    transition(time, onStart, onDone = function() {
    }) {
      this.liveSocket.transition(time, onStart, onDone);
    }
    // calls the callback with the view and target element for the given phxTarget
    // targets can be:
    //  * an element itself, then it is simply passed to liveSocket.owner;
    //  * a CID (Component ID), then we first search the component's element in the DOM
    //  * a selector, then we search the selector in the DOM and call the callback
    //    for each element found with the corresponding owner view
    withinTargets(phxTarget, callback, dom = document) {
      if (phxTarget instanceof HTMLElement || phxTarget instanceof SVGElement) {
        return this.liveSocket.owner(
          phxTarget,
          (view) => callback(view, phxTarget)
        );
      }
      if (isCid(phxTarget)) {
        const targets = dom_default.findComponentNodeList(this.id, phxTarget, dom);
        if (targets.length === 0) {
          logError(`no component found matching phx-target of ${phxTarget}`);
        } else {
          callback(this, parseInt(phxTarget));
        }
      } else {
        const targets = Array.from(dom.querySelectorAll(phxTarget));
        if (targets.length === 0) {
          logError(
            `nothing found matching the phx-target selector "${phxTarget}"`
          );
        }
        targets.forEach(
          (target) => this.liveSocket.owner(target, (view) => callback(view, target))
        );
      }
    }
    applyDiff(type, rawDiff, callback) {
      this.log(type, () => ["", clone(rawDiff)]);
      const { diff, reply, events, title } = Rendered.extract(rawDiff);
      const ev = events.reduce(
        (acc, args) => {
          if (args.length === 3 && args[2] == true) {
            acc.pre.push(args.slice(0, -1));
          } else {
            acc.post.push(args);
          }
          return acc;
        },
        { pre: [], post: [] }
      );
      this.liveSocket.dispatchEvents(ev.pre);
      const update = () => {
        callback({ diff, reply, events: ev.post });
        if (typeof title === "string" || type == "mount" && this.isMain()) {
          window.requestAnimationFrame(() => dom_default.putTitle(title));
        }
      };
      if ("onDocumentPatch" in this.liveSocket.domCallbacks) {
        this.liveSocket.triggerDOM("onDocumentPatch", [update]);
      } else {
        update();
      }
    }
    onJoin(resp) {
      const { rendered, container, liveview_version, pid } = resp;
      if (container) {
        const [tag, attrs] = container;
        this.el = dom_default.replaceRootContainer(this.el, tag, attrs);
      }
      this.childJoins = 0;
      this.joinPending = true;
      this.flash = null;
      if (this.root === this) {
        this.formsForRecovery = this.getFormsForRecovery();
      }
      if (this.isMain() && window.history.state === null) {
        browser_default.pushState("replace", {
          type: "patch",
          id: this.id,
          position: this.liveSocket.currentHistoryPosition
        });
      }
      if (liveview_version !== this.liveSocket.version()) {
        console.warn(
          `LiveView asset version mismatch. JavaScript version ${this.liveSocket.version()} vs. server ${liveview_version}. To avoid issues, please ensure that your assets use the same version as the server.`
        );
      }
      if (pid) {
        this.el.setAttribute(PHX_LV_PID, pid);
      }
      browser_default.dropLocal(
        this.liveSocket.localStorage,
        window.location.pathname,
        CONSECUTIVE_RELOADS
      );
      this.applyDiff("mount", rendered, ({ diff, events }) => {
        this.rendered = new Rendered(this.id, diff);
        const [html, streams] = this.renderContainer(null, "join");
        this.dropPendingRefs();
        this.joinCount++;
        this.joinAttempts = 0;
        this.maybeRecoverForms(html, () => {
          this.onJoinComplete(resp, html, streams, events);
        });
      });
    }
    dropPendingRefs() {
      dom_default.all(document, `[${PHX_REF_SRC}="${this.refSrc()}"]`, (el) => {
        el.removeAttribute(PHX_REF_LOADING);
        el.removeAttribute(PHX_REF_SRC);
        el.removeAttribute(PHX_REF_LOCK);
      });
    }
    onJoinComplete({ live_patch }, html, streams, events) {
      if (this.joinCount > 1 || this.parent && !this.parent.isJoinPending()) {
        return this.applyJoinPatch(live_patch, html, streams, events);
      }
      const newChildren = dom_default.findPhxChildrenInFragment(html, this.id).filter(
        (toEl) => {
          const fromEl = toEl.id && this.el.querySelector(`[id="${toEl.id}"]`);
          const phxStatic = fromEl && fromEl.getAttribute(PHX_STATIC);
          if (phxStatic) {
            toEl.setAttribute(PHX_STATIC, phxStatic);
          }
          if (fromEl) {
            fromEl.setAttribute(PHX_ROOT_ID, this.root.id);
          }
          return this.joinChild(toEl);
        }
      );
      if (newChildren.length === 0) {
        if (this.parent) {
          this.root.pendingJoinOps.push([
            this,
            () => this.applyJoinPatch(live_patch, html, streams, events)
          ]);
          this.parent.ackJoin(this);
        } else {
          this.onAllChildJoinsComplete();
          this.applyJoinPatch(live_patch, html, streams, events);
        }
      } else {
        this.root.pendingJoinOps.push([
          this,
          () => this.applyJoinPatch(live_patch, html, streams, events)
        ]);
      }
    }
    attachTrueDocEl() {
      this.el = dom_default.byId(this.id);
      this.el.setAttribute(PHX_ROOT_ID, this.root.id);
    }
    // this is invoked for dead and live views, so we must filter by
    // by owner to ensure we aren't duplicating hooks across disconnect
    // and connected states. This also handles cases where hooks exist
    // in a root layout with a LV in the body
    execNewMounted(parent = document) {
      let phxViewportTop = this.binding(PHX_VIEWPORT_TOP);
      let phxViewportBottom = this.binding(PHX_VIEWPORT_BOTTOM);
      this.all(
        parent,
        `[${phxViewportTop}], [${phxViewportBottom}]`,
        (hookEl) => {
          dom_default.maintainPrivateHooks(
            hookEl,
            hookEl,
            phxViewportTop,
            phxViewportBottom
          );
          this.maybeAddNewHook(hookEl);
        }
      );
      this.all(
        parent,
        `[${this.binding(PHX_HOOK)}], [data-phx-${PHX_HOOK}]`,
        (hookEl) => {
          this.maybeAddNewHook(hookEl);
        }
      );
      this.all(parent, `[${this.binding(PHX_MOUNTED)}]`, (el) => {
        this.maybeMounted(el);
      });
    }
    all(parent, selector, callback) {
      dom_default.all(parent, selector, (el) => {
        if (this.ownsElement(el)) {
          callback(el);
        }
      });
    }
    applyJoinPatch(live_patch, html, streams, events) {
      if (this.joinCount > 1) {
        if (this.pendingJoinOps.length) {
          this.pendingJoinOps.forEach((cb) => typeof cb === "function" && cb());
          this.pendingJoinOps = [];
        }
      }
      this.attachTrueDocEl();
      const patch = new DOMPatch(this, this.el, this.id, html, streams, null);
      patch.markPrunableContentForRemoval();
      this.performPatch(patch, false, true);
      this.joinNewChildren();
      this.execNewMounted();
      this.joinPending = false;
      this.liveSocket.dispatchEvents(events);
      this.applyPendingUpdates();
      if (live_patch) {
        const { kind, to } = live_patch;
        this.liveSocket.historyPatch(to, kind);
      }
      this.hideLoader();
      if (this.joinCount > 1) {
        this.triggerReconnected();
      }
      this.stopCallback();
    }
    triggerBeforeUpdateHook(fromEl, toEl) {
      this.liveSocket.triggerDOM("onBeforeElUpdated", [fromEl, toEl]);
      const hook = this.getHook(fromEl);
      const isIgnored = hook && dom_default.isIgnored(fromEl, this.binding(PHX_UPDATE));
      if (hook && !fromEl.isEqualNode(toEl) && !(isIgnored && isEqualObj(fromEl.dataset, toEl.dataset))) {
        hook.__beforeUpdate();
        return hook;
      }
    }
    maybeMounted(el) {
      const phxMounted = el.getAttribute(this.binding(PHX_MOUNTED));
      const hasBeenInvoked = phxMounted && dom_default.private(el, "mounted");
      if (phxMounted && !hasBeenInvoked) {
        this.liveSocket.execJS(el, phxMounted);
        dom_default.putPrivate(el, "mounted", true);
      }
    }
    maybeAddNewHook(el) {
      const newHook = this.addHook(el);
      if (newHook) {
        newHook.__mounted();
      }
    }
    performPatch(patch, pruneCids, isJoinPatch = false) {
      const removedEls = [];
      let phxChildrenAdded = false;
      const updatedHookIds = /* @__PURE__ */ new Set();
      this.liveSocket.triggerDOM("onPatchStart", [patch.targetContainer]);
      patch.after("added", (el) => {
        this.liveSocket.triggerDOM("onNodeAdded", [el]);
        const phxViewportTop = this.binding(PHX_VIEWPORT_TOP);
        const phxViewportBottom = this.binding(PHX_VIEWPORT_BOTTOM);
        dom_default.maintainPrivateHooks(el, el, phxViewportTop, phxViewportBottom);
        this.maybeAddNewHook(el);
        if (el.getAttribute) {
          this.maybeMounted(el);
        }
      });
      patch.after("phxChildAdded", (el) => {
        if (dom_default.isPhxSticky(el)) {
          this.liveSocket.joinRootViews();
        } else {
          phxChildrenAdded = true;
        }
      });
      patch.before("updated", (fromEl, toEl) => {
        const hook = this.triggerBeforeUpdateHook(fromEl, toEl);
        if (hook) {
          updatedHookIds.add(fromEl.id);
        }
        js_default.onBeforeElUpdated(fromEl, toEl);
      });
      patch.after("updated", (el) => {
        if (updatedHookIds.has(el.id)) {
          this.getHook(el).__updated();
        }
      });
      patch.after("discarded", (el) => {
        if (el.nodeType === Node.ELEMENT_NODE) {
          removedEls.push(el);
        }
      });
      patch.after(
        "transitionsDiscarded",
        (els) => this.afterElementsRemoved(els, pruneCids)
      );
      patch.perform(isJoinPatch);
      this.afterElementsRemoved(removedEls, pruneCids);
      this.liveSocket.triggerDOM("onPatchEnd", [patch.targetContainer]);
      return phxChildrenAdded;
    }
    afterElementsRemoved(elements, pruneCids) {
      const destroyedCIDs = [];
      elements.forEach((parent) => {
        const components = dom_default.all(
          parent,
          `[${PHX_VIEW_REF}="${this.id}"][${PHX_COMPONENT}]`
        );
        const hooks = dom_default.all(
          parent,
          `[${this.binding(PHX_HOOK)}], [data-phx-hook]`
        );
        components.concat(parent).forEach((el) => {
          const cid = this.componentID(el);
          if (isCid(cid) && destroyedCIDs.indexOf(cid) === -1 && el.getAttribute(PHX_VIEW_REF) === this.id) {
            destroyedCIDs.push(cid);
          }
        });
        hooks.concat(parent).forEach((hookEl) => {
          const hook = this.getHook(hookEl);
          hook && this.destroyHook(hook);
        });
      });
      if (pruneCids) {
        this.maybePushComponentsDestroyed(destroyedCIDs);
      }
    }
    joinNewChildren() {
      dom_default.findPhxChildren(document, this.id).forEach((el) => this.joinChild(el));
    }
    maybeRecoverForms(html, callback) {
      const phxChange = this.binding("change");
      const oldForms = this.root.formsForRecovery;
      const template = document.createElement("template");
      template.innerHTML = html;
      dom_default.all(template.content, `[${PHX_PORTAL}]`).forEach((portalTemplate) => {
        template.content.firstElementChild.appendChild(
          portalTemplate.content.firstElementChild
        );
      });
      const rootEl = template.content.firstElementChild;
      rootEl.id = this.id;
      rootEl.setAttribute(PHX_ROOT_ID, this.root.id);
      rootEl.setAttribute(PHX_SESSION, this.getSession());
      rootEl.setAttribute(PHX_STATIC, this.getStatic());
      rootEl.setAttribute(PHX_PARENT_ID, this.parent ? this.parent.id : null);
      const formsToRecover = (
        // we go over all forms in the new DOM; because this is only the HTML for the current
        // view, we can be sure that all forms are owned by this view:
        dom_default.all(template.content, "form").filter((newForm) => newForm.id && oldForms[newForm.id]).filter((newForm) => !this.pendingForms.has(newForm.id)).filter(
          (newForm) => oldForms[newForm.id].getAttribute(phxChange) === newForm.getAttribute(phxChange)
        ).map((newForm) => {
          return [oldForms[newForm.id], newForm];
        })
      );
      if (formsToRecover.length === 0) {
        return callback();
      }
      formsToRecover.forEach(([oldForm, newForm], i) => {
        this.pendingForms.add(newForm.id);
        this.pushFormRecovery(
          oldForm,
          newForm,
          template.content.firstElementChild,
          () => {
            this.pendingForms.delete(newForm.id);
            if (i === formsToRecover.length - 1) {
              callback();
            }
          }
        );
      });
    }
    getChildById(id) {
      return this.root.children[this.id][id];
    }
    getDescendentByEl(el) {
      if (el.id === this.id) {
        return this;
      } else {
        return this.children[el.getAttribute(PHX_PARENT_ID)]?.[el.id];
      }
    }
    destroyDescendent(id) {
      for (const parentId in this.root.children) {
        for (const childId in this.root.children[parentId]) {
          if (childId === id) {
            return this.root.children[parentId][childId].destroy();
          }
        }
      }
    }
    joinChild(el) {
      const child = this.getChildById(el.id);
      if (!child) {
        const view = new _View(el, this.liveSocket, this);
        this.root.children[this.id][view.id] = view;
        view.join();
        this.childJoins++;
        return true;
      }
    }
    isJoinPending() {
      return this.joinPending;
    }
    ackJoin(_child) {
      this.childJoins--;
      if (this.childJoins === 0) {
        if (this.parent) {
          this.parent.ackJoin(this);
        } else {
          this.onAllChildJoinsComplete();
        }
      }
    }
    onAllChildJoinsComplete() {
      this.pendingForms.clear();
      this.formsForRecovery = {};
      this.joinCallback(() => {
        this.pendingJoinOps.forEach(([view, op]) => {
          if (!view.isDestroyed()) {
            op();
          }
        });
        this.pendingJoinOps = [];
      });
    }
    update(diff, events, isPending = false) {
      if (this.isJoinPending() || this.liveSocket.hasPendingLink() && this.root.isMain()) {
        if (!isPending) {
          this.pendingDiffs.push({ diff, events });
        }
        return false;
      }
      this.rendered.mergeDiff(diff);
      let phxChildrenAdded = false;
      if (this.rendered.isComponentOnlyDiff(diff)) {
        this.liveSocket.time("component patch complete", () => {
          const parentCids = dom_default.findExistingParentCIDs(
            this.id,
            this.rendered.componentCIDs(diff)
          );
          parentCids.forEach((parentCID) => {
            if (this.componentPatch(
              this.rendered.getComponent(diff, parentCID),
              parentCID
            )) {
              phxChildrenAdded = true;
            }
          });
        });
      } else if (!isEmpty(diff)) {
        this.liveSocket.time("full patch complete", () => {
          const [html, streams] = this.renderContainer(diff, "update");
          const patch = new DOMPatch(this, this.el, this.id, html, streams, null);
          phxChildrenAdded = this.performPatch(patch, true);
        });
      }
      this.liveSocket.dispatchEvents(events);
      if (phxChildrenAdded) {
        this.joinNewChildren();
      }
      return true;
    }
    renderContainer(diff, kind) {
      return this.liveSocket.time(`toString diff (${kind})`, () => {
        const tag = this.el.tagName;
        const cids = diff ? this.rendered.componentCIDs(diff) : null;
        const { buffer: html, streams } = this.rendered.toString(cids);
        return [`<${tag}>${html}</${tag}>`, streams];
      });
    }
    componentPatch(diff, cid) {
      if (isEmpty(diff))
        return false;
      const { buffer: html, streams } = this.rendered.componentToString(cid);
      const patch = new DOMPatch(this, this.el, this.id, html, streams, cid);
      const childrenAdded = this.performPatch(patch, true);
      return childrenAdded;
    }
    getHook(el) {
      return this.viewHooks[ViewHook.elementID(el)];
    }
    addHook(el) {
      const hookElId = ViewHook.elementID(el);
      if (el.getAttribute && !this.ownsElement(el)) {
        return;
      }
      if (hookElId && !this.viewHooks[hookElId]) {
        const hook = dom_default.getCustomElHook(el) || logError(`no hook found for custom element: ${el.id}`);
        this.viewHooks[hookElId] = hook;
        hook.__attachView(this);
        return hook;
      } else if (hookElId || !el.getAttribute) {
        return;
      } else {
        const hookName = el.getAttribute(`data-phx-${PHX_HOOK}`) || el.getAttribute(this.binding(PHX_HOOK));
        if (!hookName) {
          return;
        }
        const hookDefinition = this.liveSocket.getHookDefinition(hookName);
        if (hookDefinition) {
          if (!el.id) {
            logError(
              `no DOM ID for hook "${hookName}". Hooks require a unique ID on each element.`,
              el
            );
            return;
          }
          let hookInstance;
          try {
            if (typeof hookDefinition === "function" && hookDefinition.prototype instanceof ViewHook) {
              hookInstance = new hookDefinition(this, el);
            } else if (typeof hookDefinition === "object" && hookDefinition !== null) {
              hookInstance = new ViewHook(this, el, hookDefinition);
            } else {
              logError(
                `Invalid hook definition for "${hookName}". Expected a class extending ViewHook or an object definition.`,
                el
              );
              return;
            }
          } catch (e) {
            const errorMessage = e instanceof Error ? e.message : String(e);
            logError(`Failed to create hook "${hookName}": ${errorMessage}`, el);
            return;
          }
          this.viewHooks[ViewHook.elementID(hookInstance.el)] = hookInstance;
          return hookInstance;
        } else if (hookName !== null) {
          logError(`unknown hook found for "${hookName}"`, el);
        }
      }
    }
    destroyHook(hook) {
      const hookId = ViewHook.elementID(hook.el);
      hook.__destroyed();
      hook.__cleanup__();
      delete this.viewHooks[hookId];
    }
    applyPendingUpdates() {
      this.pendingDiffs = this.pendingDiffs.filter(
        ({ diff, events }) => !this.update(diff, events, true)
      );
      this.eachChild((child) => child.applyPendingUpdates());
    }
    eachChild(callback) {
      const children = this.root.children[this.id] || {};
      for (const id in children) {
        callback(this.getChildById(id));
      }
    }
    onChannel(event, cb) {
      this.liveSocket.onChannel(this.channel, event, (resp) => {
        if (this.isJoinPending()) {
          if (this.joinCount > 1) {
            this.pendingJoinOps.push(() => cb(resp));
          } else {
            this.root.pendingJoinOps.push([this, () => cb(resp)]);
          }
        } else {
          this.liveSocket.requestDOMUpdate(() => cb(resp));
        }
      });
    }
    bindChannel() {
      this.liveSocket.onChannel(this.channel, "diff", (rawDiff) => {
        this.liveSocket.requestDOMUpdate(() => {
          this.applyDiff(
            "update",
            rawDiff,
            ({ diff, events }) => this.update(diff, events)
          );
        });
      });
      this.onChannel(
        "redirect",
        ({ to, flash }) => this.onRedirect({ to, flash })
      );
      this.onChannel("live_patch", (redir) => this.onLivePatch(redir));
      this.onChannel("live_redirect", (redir) => this.onLiveRedirect(redir));
      this.channel.onError((reason) => this.onError(reason));
      this.channel.onClose((reason) => this.onClose(reason));
    }
    destroyAllChildren() {
      this.eachChild((child) => child.destroy());
    }
    onLiveRedirect(redir) {
      const { to, kind, flash } = redir;
      const url = this.expandURL(to);
      const e = new CustomEvent("phx:server-navigate", {
        detail: { to, kind, flash }
      });
      this.liveSocket.historyRedirect(e, url, kind, flash);
    }
    onLivePatch(redir) {
      const { to, kind } = redir;
      this.href = this.expandURL(to);
      this.liveSocket.historyPatch(to, kind);
    }
    expandURL(to) {
      return to.startsWith("/") ? `${window.location.protocol}//${window.location.host}${to}` : to;
    }
    /**
     * @param {{to: string, flash?: string, reloadToken?: string}} redirect
     */
    onRedirect({ to, flash, reloadToken }) {
      this.liveSocket.redirect(to, flash, reloadToken);
    }
    isDestroyed() {
      return this.destroyed;
    }
    joinDead() {
      this.isDead = true;
    }
    joinPush() {
      this.joinPush = this.joinPush || this.channel.join();
      return this.joinPush;
    }
    join(callback) {
      this.showLoader(this.liveSocket.loaderTimeout);
      this.bindChannel();
      if (this.isMain()) {
        this.stopCallback = this.liveSocket.withPageLoading({
          to: this.href,
          kind: "initial"
        });
      }
      this.joinCallback = (onDone) => {
        onDone = onDone || function() {
        };
        callback ? callback(this.joinCount, onDone) : onDone();
      };
      this.wrapPush(() => this.channel.join(), {
        ok: (resp) => this.liveSocket.requestDOMUpdate(() => this.onJoin(resp)),
        error: (error) => this.onJoinError(error),
        timeout: () => this.onJoinError({ reason: "timeout" })
      });
    }
    onJoinError(resp) {
      if (resp.reason === "reload") {
        this.log("error", () => [
          `failed mount with ${resp.status}. Falling back to page reload`,
          resp
        ]);
        this.onRedirect({
          to: this.liveSocket.main.href,
          reloadToken: resp.token
        });
        return;
      } else if (resp.reason === "unauthorized" || resp.reason === "stale") {
        this.log("error", () => [
          "unauthorized live_redirect. Falling back to page request",
          resp
        ]);
        this.onRedirect({ to: this.liveSocket.main.href, flash: this.flash });
        return;
      }
      if (resp.redirect || resp.live_redirect) {
        this.joinPending = false;
        this.channel.leave();
      }
      if (resp.redirect) {
        return this.onRedirect(resp.redirect);
      }
      if (resp.live_redirect) {
        return this.onLiveRedirect(resp.live_redirect);
      }
      this.log("error", () => ["unable to join", resp]);
      if (this.isMain()) {
        this.displayError(
          [PHX_LOADING_CLASS, PHX_ERROR_CLASS, PHX_SERVER_ERROR_CLASS],
          { unstructuredError: resp, errorKind: "server" }
        );
        if (this.liveSocket.isConnected()) {
          this.liveSocket.reloadWithJitter(this);
        }
      } else {
        if (this.joinAttempts >= MAX_CHILD_JOIN_ATTEMPTS) {
          this.root.displayError(
            [PHX_LOADING_CLASS, PHX_ERROR_CLASS, PHX_SERVER_ERROR_CLASS],
            { unstructuredError: resp, errorKind: "server" }
          );
          this.log("error", () => [
            `giving up trying to mount after ${MAX_CHILD_JOIN_ATTEMPTS} tries`,
            resp
          ]);
          this.destroy();
        }
        const trueChildEl = dom_default.byId(this.el.id);
        if (trueChildEl) {
          dom_default.mergeAttrs(trueChildEl, this.el);
          this.displayError(
            [PHX_LOADING_CLASS, PHX_ERROR_CLASS, PHX_SERVER_ERROR_CLASS],
            { unstructuredError: resp, errorKind: "server" }
          );
          this.el = trueChildEl;
        } else {
          this.destroy();
        }
      }
    }
    onClose(reason) {
      if (this.isDestroyed()) {
        return;
      }
      if (this.isMain() && this.liveSocket.hasPendingLink() && reason !== "leave") {
        return this.liveSocket.reloadWithJitter(this);
      }
      this.destroyAllChildren();
      this.liveSocket.dropActiveElement(this);
      if (this.liveSocket.isUnloaded()) {
        this.showLoader(BEFORE_UNLOAD_LOADER_TIMEOUT);
      }
    }
    onError(reason) {
      this.onClose(reason);
      if (this.liveSocket.isConnected()) {
        this.log("error", () => ["view crashed", reason]);
      }
      if (!this.liveSocket.isUnloaded()) {
        if (this.liveSocket.isConnected()) {
          this.displayError(
            [PHX_LOADING_CLASS, PHX_ERROR_CLASS, PHX_SERVER_ERROR_CLASS],
            { unstructuredError: reason, errorKind: "server" }
          );
        } else {
          this.displayError(
            [PHX_LOADING_CLASS, PHX_ERROR_CLASS, PHX_CLIENT_ERROR_CLASS],
            { unstructuredError: reason, errorKind: "client" }
          );
        }
      }
    }
    displayError(classes, details = {}) {
      if (this.isMain()) {
        dom_default.dispatchEvent(window, "phx:page-loading-start", {
          detail: { to: this.href, kind: "error", ...details }
        });
      }
      this.showLoader();
      this.setContainerClasses(...classes);
      this.delayedDisconnected();
    }
    delayedDisconnected() {
      this.disconnectedTimer = setTimeout(() => {
        this.execAll(this.binding("disconnected"));
      }, this.liveSocket.disconnectedTimeout);
    }
    wrapPush(callerPush, receives) {
      const latency = this.liveSocket.getLatencySim();
      const withLatency = latency ? (cb) => setTimeout(() => !this.isDestroyed() && cb(), latency) : (cb) => !this.isDestroyed() && cb();
      withLatency(() => {
        callerPush().receive(
          "ok",
          (resp) => withLatency(() => receives.ok && receives.ok(resp))
        ).receive(
          "error",
          (reason) => withLatency(() => receives.error && receives.error(reason))
        ).receive(
          "timeout",
          () => withLatency(() => receives.timeout && receives.timeout())
        );
      });
    }
    pushWithReply(refGenerator, event, payload) {
      if (!this.isConnected()) {
        return Promise.reject(new Error("no connection"));
      }
      const [ref, [el], opts] = refGenerator ? refGenerator({ payload }) : [null, [], {}];
      const oldJoinCount = this.joinCount;
      let onLoadingDone = function() {
      };
      if (opts.page_loading) {
        onLoadingDone = this.liveSocket.withPageLoading({
          kind: "element",
          target: el
        });
      }
      if (typeof payload.cid !== "number") {
        delete payload.cid;
      }
      return new Promise((resolve, reject) => {
        this.wrapPush(() => this.channel.push(event, payload, PUSH_TIMEOUT), {
          ok: (resp) => {
            if (ref !== null) {
              this.lastAckRef = ref;
            }
            const finish = (hookReply) => {
              if (resp.redirect) {
                this.onRedirect(resp.redirect);
              }
              if (resp.live_patch) {
                this.onLivePatch(resp.live_patch);
              }
              if (resp.live_redirect) {
                this.onLiveRedirect(resp.live_redirect);
              }
              onLoadingDone();
              resolve({ resp, reply: hookReply, ref });
            };
            if (resp.diff) {
              this.liveSocket.requestDOMUpdate(() => {
                this.applyDiff("update", resp.diff, ({ diff, reply, events }) => {
                  if (ref !== null) {
                    this.undoRefs(ref, payload.event);
                  }
                  this.update(diff, events);
                  finish(reply);
                });
              });
            } else {
              if (ref !== null) {
                this.undoRefs(ref, payload.event);
              }
              finish(null);
            }
          },
          error: (reason) => reject(new Error(`failed with reason: ${JSON.stringify(reason)}`)),
          timeout: () => {
            reject(new Error("timeout"));
            if (this.joinCount === oldJoinCount) {
              this.liveSocket.reloadWithJitter(this, () => {
                this.log("timeout", () => [
                  "received timeout while communicating with server. Falling back to hard refresh for recovery"
                ]);
              });
            }
          }
        });
      });
    }
    undoRefs(ref, phxEvent, onlyEls) {
      if (!this.isConnected()) {
        return;
      }
      const selector = `[${PHX_REF_SRC}="${this.refSrc()}"]`;
      if (onlyEls) {
        onlyEls = new Set(onlyEls);
        dom_default.all(document, selector, (parent) => {
          if (onlyEls && !onlyEls.has(parent)) {
            return;
          }
          dom_default.all(
            parent,
            selector,
            (child) => this.undoElRef(child, ref, phxEvent)
          );
          this.undoElRef(parent, ref, phxEvent);
        });
      } else {
        dom_default.all(document, selector, (el) => this.undoElRef(el, ref, phxEvent));
      }
    }
    undoElRef(el, ref, phxEvent) {
      const elRef = new ElementRef(el);
      elRef.maybeUndo(ref, phxEvent, (clonedTree) => {
        const patch = new DOMPatch(this, el, this.id, clonedTree, [], null, {
          undoRef: ref
        });
        const phxChildrenAdded = this.performPatch(patch, true);
        dom_default.all(
          el,
          `[${PHX_REF_SRC}="${this.refSrc()}"]`,
          (child) => this.undoElRef(child, ref, phxEvent)
        );
        if (phxChildrenAdded) {
          this.joinNewChildren();
        }
      });
    }
    refSrc() {
      return this.el.id;
    }
    putRef(elements, phxEvent, eventType, opts = {}) {
      const newRef = this.ref++;
      const disableWith = this.binding(PHX_DISABLE_WITH);
      if (opts.loading) {
        const loadingEls = dom_default.all(document, opts.loading).map((el) => {
          return { el, lock: true, loading: true };
        });
        elements = elements.concat(loadingEls);
      }
      for (const { el, lock, loading } of elements) {
        if (!lock && !loading) {
          throw new Error("putRef requires lock or loading");
        }
        el.setAttribute(PHX_REF_SRC, this.refSrc());
        if (loading) {
          el.setAttribute(PHX_REF_LOADING, newRef);
        }
        if (lock) {
          el.setAttribute(PHX_REF_LOCK, newRef);
        }
        if (!loading || opts.submitter && !(el === opts.submitter || el === opts.form)) {
          continue;
        }
        const lockCompletePromise = new Promise((resolve) => {
          el.addEventListener(`phx:undo-lock:${newRef}`, () => resolve(detail), {
            once: true
          });
        });
        const loadingCompletePromise = new Promise((resolve) => {
          el.addEventListener(
            `phx:undo-loading:${newRef}`,
            () => resolve(detail),
            { once: true }
          );
        });
        el.classList.add(`phx-${eventType}-loading`);
        const disableText = el.getAttribute(disableWith);
        if (disableText !== null) {
          if (!el.getAttribute(PHX_DISABLE_WITH_RESTORE)) {
            el.setAttribute(PHX_DISABLE_WITH_RESTORE, el.textContent);
          }
          if (disableText !== "") {
            el.textContent = disableText;
          }
          el.setAttribute(
            PHX_DISABLED,
            el.getAttribute(PHX_DISABLED) || el.disabled
          );
          el.setAttribute("disabled", "");
        }
        const detail = {
          event: phxEvent,
          eventType,
          ref: newRef,
          isLoading: loading,
          isLocked: lock,
          lockElements: elements.filter(({ lock: lock2 }) => lock2).map(({ el: el2 }) => el2),
          loadingElements: elements.filter(({ loading: loading2 }) => loading2).map(({ el: el2 }) => el2),
          unlock: (els) => {
            els = Array.isArray(els) ? els : [els];
            this.undoRefs(newRef, phxEvent, els);
          },
          lockComplete: lockCompletePromise,
          loadingComplete: loadingCompletePromise,
          lock: (lockEl) => {
            return new Promise((resolve) => {
              if (this.isAcked(newRef)) {
                return resolve(detail);
              }
              lockEl.setAttribute(PHX_REF_LOCK, newRef);
              lockEl.setAttribute(PHX_REF_SRC, this.refSrc());
              lockEl.addEventListener(
                `phx:lock-stop:${newRef}`,
                () => resolve(detail),
                { once: true }
              );
            });
          }
        };
        if (opts.payload) {
          detail["payload"] = opts.payload;
        }
        if (opts.target) {
          detail["target"] = opts.target;
        }
        if (opts.originalEvent) {
          detail["originalEvent"] = opts.originalEvent;
        }
        el.dispatchEvent(
          new CustomEvent("phx:push", {
            detail,
            bubbles: true,
            cancelable: false
          })
        );
        if (phxEvent) {
          el.dispatchEvent(
            new CustomEvent(`phx:push:${phxEvent}`, {
              detail,
              bubbles: true,
              cancelable: false
            })
          );
        }
      }
      return [newRef, elements.map(({ el }) => el), opts];
    }
    isAcked(ref) {
      return this.lastAckRef !== null && this.lastAckRef >= ref;
    }
    componentID(el) {
      const cid = el.getAttribute && el.getAttribute(PHX_COMPONENT);
      return cid ? parseInt(cid) : null;
    }
    targetComponentID(target, targetCtx, opts = {}) {
      if (isCid(targetCtx)) {
        return targetCtx;
      }
      const cidOrSelector = opts.target || target.getAttribute(this.binding("target"));
      if (isCid(cidOrSelector)) {
        return parseInt(cidOrSelector);
      } else if (targetCtx && (cidOrSelector !== null || opts.target)) {
        return this.closestComponentID(targetCtx);
      } else {
        return null;
      }
    }
    closestComponentID(targetCtx) {
      if (isCid(targetCtx)) {
        return targetCtx;
      } else if (targetCtx) {
        return maybe(
          // We either use the closest data-phx-component binding, or -
          // in case of portals - continue with the portal source.
          // This is necessary if teleporting an element outside of its LiveComponent.
          targetCtx.closest(`[${PHX_COMPONENT}],[${PHX_TELEPORTED_SRC}]`),
          (el) => {
            if (el.hasAttribute(PHX_COMPONENT)) {
              return this.ownsElement(el) && this.componentID(el);
            }
            if (el.hasAttribute(PHX_TELEPORTED_SRC)) {
              const portalParent = dom_default.byId(el.getAttribute(PHX_TELEPORTED_SRC));
              return this.closestComponentID(portalParent);
            }
          }
        );
      } else {
        return null;
      }
    }
    pushHookEvent(el, targetCtx, event, payload) {
      if (!this.isConnected()) {
        this.log("hook", () => [
          "unable to push hook event. LiveView not connected",
          event,
          payload
        ]);
        return Promise.reject(
          new Error("unable to push hook event. LiveView not connected")
        );
      }
      const refGenerator = () => this.putRef([{ el, loading: true, lock: true }], event, "hook", {
        payload,
        target: targetCtx
      });
      return this.pushWithReply(refGenerator, "event", {
        type: "hook",
        event,
        value: payload,
        cid: this.closestComponentID(targetCtx)
      }).then(({ resp: _resp, reply, ref }) => ({ reply, ref }));
    }
    extractMeta(el, meta, value) {
      const prefix = this.binding("value-");
      for (let i = 0; i < el.attributes.length; i++) {
        if (!meta) {
          meta = {};
        }
        const name = el.attributes[i].name;
        if (name.startsWith(prefix)) {
          meta[name.replace(prefix, "")] = el.getAttribute(name);
        }
      }
      if (el.value !== void 0 && !(el instanceof HTMLFormElement)) {
        if (!meta) {
          meta = {};
        }
        meta.value = el.value;
        if (el.tagName === "INPUT" && CHECKABLE_INPUTS.indexOf(el.type) >= 0 && !el.checked) {
          delete meta.value;
        }
      }
      if (value) {
        if (!meta) {
          meta = {};
        }
        for (const key in value) {
          meta[key] = value[key];
        }
      }
      return meta;
    }
    pushEvent(type, el, targetCtx, phxEvent, meta, opts = {}, onReply) {
      this.pushWithReply(
        (maybePayload) => this.putRef([{ el, loading: true, lock: true }], phxEvent, type, {
          ...opts,
          payload: maybePayload?.payload
        }),
        "event",
        {
          type,
          event: phxEvent,
          value: this.extractMeta(el, meta, opts.value),
          cid: this.targetComponentID(el, targetCtx, opts)
        }
      ).then(({ reply }) => onReply && onReply(reply)).catch((error) => logError("Failed to push event", error));
    }
    pushFileProgress(fileEl, entryRef, progress, onReply = function() {
    }) {
      this.liveSocket.withinOwners(fileEl.form, (view, targetCtx) => {
        view.pushWithReply(null, "progress", {
          event: fileEl.getAttribute(view.binding(PHX_PROGRESS)),
          ref: fileEl.getAttribute(PHX_UPLOAD_REF),
          entry_ref: entryRef,
          progress,
          cid: view.targetComponentID(fileEl.form, targetCtx)
        }).then(() => onReply()).catch((error) => logError("Failed to push file progress", error));
      });
    }
    pushInput(inputEl, targetCtx, forceCid, phxEvent, opts, callback) {
      if (!inputEl.form) {
        throw new Error("form events require the input to be inside a form");
      }
      let uploads;
      const cid = isCid(forceCid) ? forceCid : this.targetComponentID(inputEl.form, targetCtx, opts);
      const refGenerator = (maybePayload) => {
        return this.putRef(
          [
            { el: inputEl, loading: true, lock: true },
            { el: inputEl.form, loading: true, lock: true }
          ],
          phxEvent,
          "change",
          { ...opts, payload: maybePayload?.payload }
        );
      };
      let formData;
      const meta = this.extractMeta(inputEl.form, {}, opts.value);
      const serializeOpts = {};
      if (inputEl instanceof HTMLButtonElement) {
        serializeOpts.submitter = inputEl;
      }
      if (inputEl.getAttribute(this.binding("change"))) {
        formData = serializeForm(inputEl.form, serializeOpts, [inputEl.name]);
      } else {
        formData = serializeForm(inputEl.form, serializeOpts);
      }
      if (dom_default.isUploadInput(inputEl) && inputEl.files && inputEl.files.length > 0) {
        LiveUploader.trackFiles(inputEl, Array.from(inputEl.files));
      }
      uploads = LiveUploader.serializeUploads(inputEl);
      const event = {
        type: "form",
        event: phxEvent,
        value: formData,
        meta: {
          // no target was implicitly sent as "undefined" in LV <= 1.0.5, therefore
          // we have to keep it. In 1.0.6 we switched from passing meta as URL encoded data
          // to passing it directly in the event, but the JSON encode would drop keys with
          // undefined values.
          _target: opts._target || "undefined",
          ...meta
        },
        uploads,
        cid
      };
      this.pushWithReply(refGenerator, "event", event).then(({ resp }) => {
        if (dom_default.isUploadInput(inputEl) && dom_default.isAutoUpload(inputEl)) {
          ElementRef.onUnlock(inputEl, () => {
            if (LiveUploader.filesAwaitingPreflight(inputEl).length > 0) {
              const [ref, _els] = refGenerator();
              this.undoRefs(ref, phxEvent, [inputEl.form]);
              this.uploadFiles(
                inputEl.form,
                phxEvent,
                targetCtx,
                ref,
                cid,
                (_uploads) => {
                  callback && callback(resp);
                  this.triggerAwaitingSubmit(inputEl.form, phxEvent);
                  this.undoRefs(ref, phxEvent);
                }
              );
            }
          });
        } else {
          callback && callback(resp);
        }
      }).catch((error) => logError("Failed to push input event", error));
    }
    triggerAwaitingSubmit(formEl, phxEvent) {
      const awaitingSubmit = this.getScheduledSubmit(formEl);
      if (awaitingSubmit) {
        const [_el, _ref, _opts, callback] = awaitingSubmit;
        this.cancelSubmit(formEl, phxEvent);
        callback();
      }
    }
    getScheduledSubmit(formEl) {
      return this.formSubmits.find(
        ([el, _ref, _opts, _callback]) => el.isSameNode(formEl)
      );
    }
    scheduleSubmit(formEl, ref, opts, callback) {
      if (this.getScheduledSubmit(formEl)) {
        return true;
      }
      this.formSubmits.push([formEl, ref, opts, callback]);
    }
    cancelSubmit(formEl, phxEvent) {
      this.formSubmits = this.formSubmits.filter(
        ([el, ref, _opts, _callback]) => {
          if (el.isSameNode(formEl)) {
            this.undoRefs(ref, phxEvent);
            return false;
          } else {
            return true;
          }
        }
      );
    }
    disableForm(formEl, phxEvent, opts = {}) {
      const filterIgnored = (el) => {
        const userIgnored = closestPhxBinding(
          el,
          `${this.binding(PHX_UPDATE)}=ignore`,
          el.form
        );
        return !(userIgnored || closestPhxBinding(el, "data-phx-update=ignore", el.form));
      };
      const filterDisables = (el) => {
        return el.hasAttribute(this.binding(PHX_DISABLE_WITH));
      };
      const filterButton = (el) => el.tagName == "BUTTON";
      const filterInput = (el) => ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName);
      const formElements = Array.from(formEl.elements);
      const disables = formElements.filter(filterDisables);
      const buttons = formElements.filter(filterButton).filter(filterIgnored);
      const inputs = formElements.filter(filterInput).filter(filterIgnored);
      buttons.forEach((button) => {
        button.setAttribute(PHX_DISABLED, button.disabled);
        button.disabled = true;
      });
      inputs.forEach((input) => {
        input.setAttribute(PHX_READONLY, input.readOnly);
        input.readOnly = true;
        if (input.files) {
          input.setAttribute(PHX_DISABLED, input.disabled);
          input.disabled = true;
        }
      });
      const formEls = disables.concat(buttons).concat(inputs).map((el) => {
        return { el, loading: true, lock: true };
      });
      const els = [{ el: formEl, loading: true, lock: false }].concat(formEls).reverse();
      return this.putRef(els, phxEvent, "submit", opts);
    }
    pushFormSubmit(formEl, targetCtx, phxEvent, submitter, opts, onReply) {
      const refGenerator = (maybePayload) => this.disableForm(formEl, phxEvent, {
        ...opts,
        form: formEl,
        payload: maybePayload?.payload,
        submitter
      });
      dom_default.putPrivate(formEl, "submitter", submitter);
      const cid = this.targetComponentID(formEl, targetCtx);
      if (LiveUploader.hasUploadsInProgress(formEl)) {
        const [ref, _els] = refGenerator();
        const push = () => this.pushFormSubmit(
          formEl,
          targetCtx,
          phxEvent,
          submitter,
          opts,
          onReply
        );
        return this.scheduleSubmit(formEl, ref, opts, push);
      } else if (LiveUploader.inputsAwaitingPreflight(formEl).length > 0) {
        const [ref, els] = refGenerator();
        const proxyRefGen = () => [ref, els, opts];
        this.uploadFiles(formEl, phxEvent, targetCtx, ref, cid, (_uploads) => {
          if (LiveUploader.inputsAwaitingPreflight(formEl).length > 0) {
            return this.undoRefs(ref, phxEvent);
          }
          const meta = this.extractMeta(formEl, {}, opts.value);
          const formData = serializeForm(formEl, { submitter });
          this.pushWithReply(proxyRefGen, "event", {
            type: "form",
            event: phxEvent,
            value: formData,
            meta,
            cid
          }).then(({ resp }) => onReply(resp)).catch((error) => logError("Failed to push form submit", error));
        });
      } else if (!(formEl.hasAttribute(PHX_REF_SRC) && formEl.classList.contains("phx-submit-loading"))) {
        const meta = this.extractMeta(formEl, {}, opts.value);
        const formData = serializeForm(formEl, { submitter });
        this.pushWithReply(refGenerator, "event", {
          type: "form",
          event: phxEvent,
          value: formData,
          meta,
          cid
        }).then(({ resp }) => onReply(resp)).catch((error) => logError("Failed to push form submit", error));
      }
    }
    uploadFiles(formEl, phxEvent, targetCtx, ref, cid, onComplete) {
      const joinCountAtUpload = this.joinCount;
      const inputEls = LiveUploader.activeFileInputs(formEl);
      let numFileInputsInProgress = inputEls.length;
      inputEls.forEach((inputEl) => {
        const uploader = new LiveUploader(inputEl, this, () => {
          numFileInputsInProgress--;
          if (numFileInputsInProgress === 0) {
            onComplete();
          }
        });
        const entries = uploader.entries().map((entry) => entry.toPreflightPayload());
        if (entries.length === 0) {
          numFileInputsInProgress--;
          return;
        }
        const payload = {
          ref: inputEl.getAttribute(PHX_UPLOAD_REF),
          entries,
          cid: this.targetComponentID(inputEl.form, targetCtx)
        };
        this.log("upload", () => ["sending preflight request", payload]);
        this.pushWithReply(null, "allow_upload", payload).then(({ resp }) => {
          this.log("upload", () => ["got preflight response", resp]);
          uploader.entries().forEach((entry) => {
            if (resp.entries && !resp.entries[entry.ref]) {
              this.handleFailedEntryPreflight(
                entry.ref,
                "failed preflight",
                uploader
              );
            }
          });
          if (resp.error || Object.keys(resp.entries).length === 0) {
            this.undoRefs(ref, phxEvent);
            const errors = resp.error || [];
            errors.map(([entry_ref, reason]) => {
              this.handleFailedEntryPreflight(entry_ref, reason, uploader);
            });
          } else {
            const onError = (callback) => {
              this.channel.onError(() => {
                if (this.joinCount === joinCountAtUpload) {
                  callback();
                }
              });
            };
            uploader.initAdapterUpload(resp, onError, this.liveSocket);
          }
        }).catch((error) => logError("Failed to push upload", error));
      });
    }
    handleFailedEntryPreflight(uploadRef, reason, uploader) {
      if (uploader.isAutoUpload()) {
        const entry = uploader.entries().find((entry2) => entry2.ref === uploadRef.toString());
        if (entry) {
          entry.cancel();
        }
      } else {
        uploader.entries().map((entry) => entry.cancel());
      }
      this.log("upload", () => [`error for entry ${uploadRef}`, reason]);
    }
    dispatchUploads(targetCtx, name, filesOrBlobs) {
      const targetElement = this.targetCtxElement(targetCtx) || this.el;
      const inputs = dom_default.findUploadInputs(targetElement).filter(
        (el) => el.name === name
      );
      if (inputs.length === 0) {
        logError(`no live file inputs found matching the name "${name}"`);
      } else if (inputs.length > 1) {
        logError(`duplicate live file inputs found matching the name "${name}"`);
      } else {
        dom_default.dispatchEvent(inputs[0], PHX_TRACK_UPLOADS, {
          detail: { files: filesOrBlobs }
        });
      }
    }
    targetCtxElement(targetCtx) {
      if (isCid(targetCtx)) {
        const [target] = dom_default.findComponentNodeList(this.id, targetCtx);
        return target;
      } else if (targetCtx) {
        return targetCtx;
      } else {
        return null;
      }
    }
    pushFormRecovery(oldForm, newForm, templateDom, callback) {
      const phxChange = this.binding("change");
      const phxTarget = newForm.getAttribute(this.binding("target")) || newForm;
      const phxEvent = newForm.getAttribute(this.binding(PHX_AUTO_RECOVER)) || newForm.getAttribute(this.binding("change"));
      const inputs = Array.from(oldForm.elements).filter(
        (el) => dom_default.isFormInput(el) && el.name && !el.hasAttribute(phxChange)
      );
      if (inputs.length === 0) {
        callback();
        return;
      }
      inputs.forEach(
        (input2) => input2.hasAttribute(PHX_UPLOAD_REF) && LiveUploader.clearFiles(input2)
      );
      const input = inputs.find((el) => el.type !== "hidden") || inputs[0];
      let pending = 0;
      this.withinTargets(
        phxTarget,
        (targetView, targetCtx) => {
          const cid = this.targetComponentID(newForm, targetCtx);
          pending++;
          let e = new CustomEvent("phx:form-recovery", {
            detail: { sourceElement: oldForm }
          });
          js_default.exec(e, "change", phxEvent, this, input, [
            "push",
            {
              _target: input.name,
              targetView,
              targetCtx,
              newCid: cid,
              callback: () => {
                pending--;
                if (pending === 0) {
                  callback();
                }
              }
            }
          ]);
        },
        templateDom
      );
    }
    pushLinkPatch(e, href, targetEl, callback) {
      const linkRef = this.liveSocket.setPendingLink(href);
      const loading = e.isTrusted && e.type !== "popstate";
      const refGen = targetEl ? () => this.putRef(
        [{ el: targetEl, loading, lock: true }],
        null,
        "click"
      ) : null;
      const fallback = () => this.liveSocket.redirect(window.location.href);
      const url = href.startsWith("/") ? `${location.protocol}//${location.host}${href}` : href;
      this.pushWithReply(refGen, "live_patch", { url }).then(
        ({ resp }) => {
          this.liveSocket.requestDOMUpdate(() => {
            if (resp.link_redirect) {
              this.liveSocket.replaceMain(href, null, callback, linkRef);
            } else if (resp.redirect) {
              return;
            } else {
              if (this.liveSocket.commitPendingLink(linkRef)) {
                this.href = href;
              }
              this.applyPendingUpdates();
              callback && callback(linkRef);
            }
          });
        },
        ({ error: _error, timeout: _timeout }) => fallback()
      );
    }
    getFormsForRecovery() {
      if (this.joinCount === 0) {
        return {};
      }
      const phxChange = this.binding("change");
      return dom_default.all(
        document,
        `#${CSS.escape(this.id)} form[${phxChange}], [${PHX_TELEPORTED_REF}="${CSS.escape(this.id)}"] form[${phxChange}]`
      ).filter((form) => form.id).filter((form) => form.elements.length > 0).filter(
        (form) => form.getAttribute(this.binding(PHX_AUTO_RECOVER)) !== "ignore"
      ).map((form) => {
        const clonedForm = form.cloneNode(true);
        morphdom_esm_default(clonedForm, form, {
          onBeforeElUpdated: (fromEl, toEl) => {
            dom_default.copyPrivates(fromEl, toEl);
            if (fromEl.getAttribute("form") === form.id) {
              fromEl.parentNode.removeChild(fromEl);
              return false;
            }
            return true;
          }
        });
        const externalElements = document.querySelectorAll(
          `[form="${CSS.escape(form.id)}"]`
        );
        Array.from(externalElements).forEach((el) => {
          const clonedEl = (
            /** @type {HTMLElement} */
            el.cloneNode(true)
          );
          morphdom_esm_default(clonedEl, el);
          dom_default.copyPrivates(clonedEl, el);
          clonedEl.removeAttribute("form");
          clonedForm.appendChild(clonedEl);
        });
        return clonedForm;
      }).reduce((acc, form) => {
        acc[form.id] = form;
        return acc;
      }, {});
    }
    maybePushComponentsDestroyed(destroyedCIDs) {
      let willDestroyCIDs = destroyedCIDs.filter((cid) => {
        return dom_default.findComponentNodeList(this.id, cid).length === 0;
      });
      const onError = (error) => {
        if (!this.isDestroyed()) {
          logError("Failed to push components destroyed", error);
        }
      };
      if (willDestroyCIDs.length > 0) {
        willDestroyCIDs.forEach((cid) => this.rendered.resetRender(cid));
        this.pushWithReply(null, "cids_will_destroy", { cids: willDestroyCIDs }).then(() => {
          this.liveSocket.requestDOMUpdate(() => {
            let completelyDestroyCIDs = willDestroyCIDs.filter((cid) => {
              return dom_default.findComponentNodeList(this.id, cid).length === 0;
            });
            if (completelyDestroyCIDs.length > 0) {
              this.pushWithReply(null, "cids_destroyed", {
                cids: completelyDestroyCIDs
              }).then(({ resp }) => {
                this.rendered.pruneCIDs(resp.cids);
              }).catch(onError);
            }
          });
        }).catch(onError);
      }
    }
    ownsElement(el) {
      let parentViewEl = dom_default.closestViewEl(el);
      return el.getAttribute(PHX_PARENT_ID) === this.id || parentViewEl && parentViewEl.id === this.id || !parentViewEl && this.isDead;
    }
    submitForm(form, targetCtx, phxEvent, submitter, opts = {}) {
      dom_default.putPrivate(form, PHX_HAS_SUBMITTED, true);
      const inputs = Array.from(form.elements);
      inputs.forEach((input) => dom_default.putPrivate(input, PHX_HAS_SUBMITTED, true));
      this.liveSocket.blurActiveElement(this);
      this.pushFormSubmit(form, targetCtx, phxEvent, submitter, opts, () => {
        this.liveSocket.restorePreviouslyActiveFocus();
      });
    }
    binding(kind) {
      return this.liveSocket.binding(kind);
    }
    // phx-portal
    pushPortalElementId(id) {
      this.portalElementIds.add(id);
    }
    dropPortalElementId(id) {
      this.portalElementIds.delete(id);
    }
    destroyPortalElements() {
      if (!this.liveSocket.unloaded) {
        this.portalElementIds.forEach((id) => {
          const el = document.getElementById(id);
          if (el) {
            el.remove();
          }
        });
      }
    }
  };
  var LiveSocket = class {
    constructor(url, phxSocket, opts = {}) {
      this.unloaded = false;
      if (!phxSocket || phxSocket.constructor.name === "Object") {
        throw new Error(`
      a phoenix Socket must be provided as the second argument to the LiveSocket constructor. For example:

          import {Socket} from "phoenix"
          import {LiveSocket} from "phoenix_live_view"
          let liveSocket = new LiveSocket("/live", Socket, {...})
      `);
      }
      this.socket = new phxSocket(url, opts);
      this.bindingPrefix = opts.bindingPrefix || BINDING_PREFIX;
      this.opts = opts;
      this.params = closure2(opts.params || {});
      this.viewLogger = opts.viewLogger;
      this.metadataCallbacks = opts.metadata || {};
      this.defaults = Object.assign(clone(DEFAULTS), opts.defaults || {});
      this.prevActive = null;
      this.silenced = false;
      this.main = null;
      this.outgoingMainEl = null;
      this.clickStartedAtTarget = null;
      this.linkRef = 1;
      this.roots = {};
      this.href = window.location.href;
      this.pendingLink = null;
      this.currentLocation = clone(window.location);
      this.hooks = opts.hooks || {};
      this.uploaders = opts.uploaders || {};
      this.loaderTimeout = opts.loaderTimeout || LOADER_TIMEOUT;
      this.disconnectedTimeout = opts.disconnectedTimeout || DISCONNECTED_TIMEOUT;
      this.reloadWithJitterTimer = null;
      this.maxReloads = opts.maxReloads || MAX_RELOADS;
      this.reloadJitterMin = opts.reloadJitterMin || RELOAD_JITTER_MIN;
      this.reloadJitterMax = opts.reloadJitterMax || RELOAD_JITTER_MAX;
      this.failsafeJitter = opts.failsafeJitter || FAILSAFE_JITTER;
      this.localStorage = opts.localStorage || window.localStorage;
      this.sessionStorage = opts.sessionStorage || window.sessionStorage;
      this.boundTopLevelEvents = false;
      this.boundEventNames = /* @__PURE__ */ new Set();
      this.blockPhxChangeWhileComposing = opts.blockPhxChangeWhileComposing || false;
      this.serverCloseRef = null;
      this.domCallbacks = Object.assign(
        {
          jsQuerySelectorAll: null,
          onPatchStart: closure2(),
          onPatchEnd: closure2(),
          onNodeAdded: closure2(),
          onBeforeElUpdated: closure2()
        },
        opts.dom || {}
      );
      this.transitions = new TransitionSet();
      this.currentHistoryPosition = parseInt(this.sessionStorage.getItem(PHX_LV_HISTORY_POSITION)) || 0;
      window.addEventListener("pagehide", (_e) => {
        this.unloaded = true;
      });
      this.socket.onOpen(() => {
        if (this.isUnloaded()) {
          window.location.reload();
        }
      });
    }
    // public
    version() {
      return "1.1.23";
    }
    isProfileEnabled() {
      return this.sessionStorage.getItem(PHX_LV_PROFILE) === "true";
    }
    isDebugEnabled() {
      return this.sessionStorage.getItem(PHX_LV_DEBUG) === "true";
    }
    isDebugDisabled() {
      return this.sessionStorage.getItem(PHX_LV_DEBUG) === "false";
    }
    enableDebug() {
      this.sessionStorage.setItem(PHX_LV_DEBUG, "true");
    }
    enableProfiling() {
      this.sessionStorage.setItem(PHX_LV_PROFILE, "true");
    }
    disableDebug() {
      this.sessionStorage.setItem(PHX_LV_DEBUG, "false");
    }
    disableProfiling() {
      this.sessionStorage.removeItem(PHX_LV_PROFILE);
    }
    enableLatencySim(upperBoundMs) {
      this.enableDebug();
      console.log(
        "latency simulator enabled for the duration of this browser session. Call disableLatencySim() to disable"
      );
      this.sessionStorage.setItem(PHX_LV_LATENCY_SIM, upperBoundMs);
    }
    disableLatencySim() {
      this.sessionStorage.removeItem(PHX_LV_LATENCY_SIM);
    }
    getLatencySim() {
      const str = this.sessionStorage.getItem(PHX_LV_LATENCY_SIM);
      return str ? parseInt(str) : null;
    }
    getSocket() {
      return this.socket;
    }
    connect() {
      if (window.location.hostname === "localhost" && !this.isDebugDisabled()) {
        this.enableDebug();
      }
      const doConnect = () => {
        this.resetReloadStatus();
        if (this.joinRootViews()) {
          this.bindTopLevelEvents();
          this.socket.connect();
        } else if (this.main) {
          this.socket.connect();
        } else {
          this.bindTopLevelEvents({ dead: true });
        }
        this.joinDeadView();
      };
      if (["complete", "loaded", "interactive"].indexOf(document.readyState) >= 0) {
        doConnect();
      } else {
        document.addEventListener("DOMContentLoaded", () => doConnect());
      }
    }
    disconnect(callback) {
      clearTimeout(this.reloadWithJitterTimer);
      if (this.serverCloseRef) {
        this.socket.off(this.serverCloseRef);
        this.serverCloseRef = null;
      }
      this.socket.disconnect(callback);
    }
    replaceTransport(transport) {
      clearTimeout(this.reloadWithJitterTimer);
      this.socket.replaceTransport(transport);
      this.connect();
    }
    /**
     * @param {HTMLElement} el
     * @param {string} encodedJS
     * @param {string | null} [eventType]
     */
    execJS(el, encodedJS, eventType = null) {
      const e = new CustomEvent("phx:exec", { detail: { sourceElement: el } });
      this.owner(el, (view) => js_default.exec(e, eventType, encodedJS, view, el));
    }
    /**
     * Returns an object with methods to manipulate the DOM and execute JavaScript.
     * The applied changes integrate with server DOM patching.
     *
     * @returns {import("./js_commands").LiveSocketJSCommands}
     */
    js() {
      return js_commands_default(this, "js");
    }
    // private
    unload() {
      if (this.unloaded) {
        return;
      }
      if (this.main && this.isConnected()) {
        this.log(this.main, "socket", () => ["disconnect for page nav"]);
      }
      this.unloaded = true;
      this.destroyAllViews();
      this.disconnect();
    }
    triggerDOM(kind, args) {
      this.domCallbacks[kind](...args);
    }
    time(name, func) {
      if (!this.isProfileEnabled() || !console.time) {
        return func();
      }
      console.time(name);
      const result = func();
      console.timeEnd(name);
      return result;
    }
    log(view, kind, msgCallback) {
      if (this.viewLogger) {
        const [msg, obj] = msgCallback();
        this.viewLogger(view, kind, msg, obj);
      } else if (this.isDebugEnabled()) {
        const [msg, obj] = msgCallback();
        debug(view, kind, msg, obj);
      }
    }
    requestDOMUpdate(callback) {
      this.transitions.after(callback);
    }
    asyncTransition(promise) {
      this.transitions.addAsyncTransition(promise);
    }
    transition(time, onStart, onDone = function() {
    }) {
      this.transitions.addTransition(time, onStart, onDone);
    }
    onChannel(channel, event, cb) {
      channel.on(event, (data) => {
        const latency = this.getLatencySim();
        if (!latency) {
          cb(data);
        } else {
          setTimeout(() => cb(data), latency);
        }
      });
    }
    reloadWithJitter(view, log) {
      clearTimeout(this.reloadWithJitterTimer);
      this.disconnect();
      const minMs = this.reloadJitterMin;
      const maxMs = this.reloadJitterMax;
      let afterMs = Math.floor(Math.random() * (maxMs - minMs + 1)) + minMs;
      const tries = browser_default.updateLocal(
        this.localStorage,
        window.location.pathname,
        CONSECUTIVE_RELOADS,
        0,
        (count) => count + 1
      );
      if (tries >= this.maxReloads) {
        afterMs = this.failsafeJitter;
      }
      this.reloadWithJitterTimer = setTimeout(() => {
        if (view.isDestroyed() || view.isConnected()) {
          return;
        }
        view.destroy();
        log ? log() : this.log(view, "join", () => [
          `encountered ${tries} consecutive reloads`
        ]);
        if (tries >= this.maxReloads) {
          this.log(view, "join", () => [
            `exceeded ${this.maxReloads} consecutive reloads. Entering failsafe mode`
          ]);
        }
        if (this.hasPendingLink()) {
          window.location = this.pendingLink;
        } else {
          window.location.reload();
        }
      }, afterMs);
    }
    getHookDefinition(name) {
      if (!name) {
        return;
      }
      return this.maybeInternalHook(name) || this.hooks[name] || this.maybeRuntimeHook(name);
    }
    maybeInternalHook(name) {
      return name && name.startsWith("Phoenix.") && hooks_default[name.split(".")[1]];
    }
    maybeRuntimeHook(name) {
      const runtimeHook = document.querySelector(
        `script[${PHX_RUNTIME_HOOK}="${CSS.escape(name)}"]`
      );
      if (!runtimeHook) {
        return;
      }
      let callbacks = window[`phx_hook_${name}`];
      if (!callbacks || typeof callbacks !== "function") {
        logError("a runtime hook must be a function", runtimeHook);
        return;
      }
      const hookDefiniton = callbacks();
      if (hookDefiniton && (typeof hookDefiniton === "object" || typeof hookDefiniton === "function")) {
        return hookDefiniton;
      }
      logError(
        "runtime hook must return an object with hook callbacks or an instance of ViewHook",
        runtimeHook
      );
    }
    isUnloaded() {
      return this.unloaded;
    }
    isConnected() {
      return this.socket.isConnected();
    }
    getBindingPrefix() {
      return this.bindingPrefix;
    }
    binding(kind) {
      return `${this.getBindingPrefix()}${kind}`;
    }
    channel(topic, params) {
      return this.socket.channel(topic, params);
    }
    joinDeadView() {
      const body = document.body;
      if (body && !this.isPhxView(body) && !this.isPhxView(document.firstElementChild)) {
        const view = this.newRootView(body);
        view.setHref(this.getHref());
        view.joinDead();
        if (!this.main) {
          this.main = view;
        }
        window.requestAnimationFrame(() => {
          view.execNewMounted();
          this.maybeScroll(history.state?.scroll);
        });
      }
    }
    joinRootViews() {
      let rootsFound = false;
      dom_default.all(
        document,
        `${PHX_VIEW_SELECTOR}:not([${PHX_PARENT_ID}])`,
        (rootEl) => {
          if (!this.getRootById(rootEl.id)) {
            const view = this.newRootView(rootEl);
            if (!dom_default.isPhxSticky(rootEl)) {
              view.setHref(this.getHref());
            }
            view.join();
            if (rootEl.hasAttribute(PHX_MAIN)) {
              this.main = view;
            }
          }
          rootsFound = true;
        }
      );
      return rootsFound;
    }
    redirect(to, flash, reloadToken) {
      if (reloadToken) {
        browser_default.setCookie(PHX_RELOAD_STATUS, reloadToken, 60);
      }
      this.unload();
      browser_default.redirect(to, flash);
    }
    replaceMain(href, flash, callback = null, linkRef = this.setPendingLink(href)) {
      const liveReferer = this.currentLocation.href;
      this.outgoingMainEl = this.outgoingMainEl || this.main.el;
      const stickies = dom_default.findPhxSticky(document) || [];
      const removeEls = dom_default.all(
        this.outgoingMainEl,
        `[${this.binding("remove")}]`
      ).filter((el) => !dom_default.isChildOfAny(el, stickies));
      const newMainEl = dom_default.cloneNode(this.outgoingMainEl, "");
      this.main.showLoader(this.loaderTimeout);
      this.main.destroy();
      this.main = this.newRootView(newMainEl, flash, liveReferer);
      this.main.setRedirect(href);
      this.transitionRemoves(removeEls);
      this.main.join((joinCount, onDone) => {
        if (joinCount === 1 && this.commitPendingLink(linkRef)) {
          this.requestDOMUpdate(() => {
            removeEls.forEach((el) => el.remove());
            stickies.forEach((el) => newMainEl.appendChild(el));
            this.outgoingMainEl.replaceWith(newMainEl);
            this.outgoingMainEl = null;
            callback && callback(linkRef);
            onDone();
          });
        }
      });
    }
    transitionRemoves(elements, callback) {
      const removeAttr = this.binding("remove");
      const silenceEvents = (e) => {
        e.preventDefault();
        e.stopImmediatePropagation();
      };
      elements.forEach((el) => {
        for (const event of this.boundEventNames) {
          el.addEventListener(event, silenceEvents, true);
        }
        this.execJS(el, el.getAttribute(removeAttr), "remove");
      });
      this.requestDOMUpdate(() => {
        elements.forEach((el) => {
          for (const event of this.boundEventNames) {
            el.removeEventListener(event, silenceEvents, true);
          }
        });
        callback && callback();
      });
    }
    isPhxView(el) {
      return el.getAttribute && el.getAttribute(PHX_SESSION) !== null;
    }
    newRootView(el, flash, liveReferer) {
      const view = new View(el, this, null, flash, liveReferer);
      this.roots[view.id] = view;
      return view;
    }
    owner(childEl, callback) {
      let view;
      const viewEl = dom_default.closestViewEl(childEl);
      if (viewEl) {
        view = this.getViewByEl(viewEl);
      } else {
        if (!childEl.isConnected) {
          return null;
        }
        view = this.main;
      }
      return view && callback ? callback(view) : view;
    }
    withinOwners(childEl, callback) {
      this.owner(childEl, (view) => callback(view, childEl));
    }
    getViewByEl(el) {
      const rootId = el.getAttribute(PHX_ROOT_ID);
      return maybe(
        this.getRootById(rootId),
        (root) => root.getDescendentByEl(el)
      );
    }
    getRootById(id) {
      return this.roots[id];
    }
    destroyAllViews() {
      for (const id in this.roots) {
        this.roots[id].destroy();
        delete this.roots[id];
      }
      this.main = null;
    }
    destroyViewByEl(el) {
      const root = this.getRootById(el.getAttribute(PHX_ROOT_ID));
      if (root && root.id === el.id) {
        root.destroy();
        delete this.roots[root.id];
      } else if (root) {
        root.destroyDescendent(el.id);
      }
    }
    getActiveElement() {
      return document.activeElement;
    }
    dropActiveElement(view) {
      if (this.prevActive && view.ownsElement(this.prevActive)) {
        this.prevActive = null;
      }
    }
    restorePreviouslyActiveFocus() {
      if (this.prevActive && this.prevActive !== document.body && this.prevActive instanceof HTMLElement) {
        this.prevActive.focus();
      }
    }
    blurActiveElement() {
      this.prevActive = this.getActiveElement();
      if (this.prevActive !== document.body && this.prevActive instanceof HTMLElement) {
        this.prevActive.blur();
      }
    }
    /**
     * @param {{dead?: boolean}} [options={}]
     */
    bindTopLevelEvents({ dead } = {}) {
      if (this.boundTopLevelEvents) {
        return;
      }
      this.boundTopLevelEvents = true;
      this.serverCloseRef = this.socket.onClose((event) => {
        if (event && event.code === 1e3 && this.main) {
          return this.reloadWithJitter(this.main);
        }
      });
      document.body.addEventListener("click", function() {
      });
      window.addEventListener(
        "pageshow",
        (e) => {
          if (e.persisted) {
            this.getSocket().disconnect();
            this.withPageLoading({ to: window.location.href, kind: "redirect" });
            window.location.reload();
          }
        },
        true
      );
      if (!dead) {
        this.bindNav();
      }
      this.bindClicks();
      if (!dead) {
        this.bindForms();
      }
      this.bind(
        { keyup: "keyup", keydown: "keydown" },
        (e, type, view, targetEl, phxEvent, _phxTarget) => {
          const matchKey = targetEl.getAttribute(this.binding(PHX_KEY));
          const pressedKey = e.key && e.key.toLowerCase();
          if (matchKey && matchKey.toLowerCase() !== pressedKey) {
            return;
          }
          const data = { key: e.key, ...this.eventMeta(type, e, targetEl) };
          js_default.exec(e, type, phxEvent, view, targetEl, ["push", { data }]);
        }
      );
      this.bind(
        { blur: "focusout", focus: "focusin" },
        (e, type, view, targetEl, phxEvent, phxTarget) => {
          if (!phxTarget) {
            const data = { key: e.key, ...this.eventMeta(type, e, targetEl) };
            js_default.exec(e, type, phxEvent, view, targetEl, ["push", { data }]);
          }
        }
      );
      this.bind(
        { blur: "blur", focus: "focus" },
        (e, type, view, targetEl, phxEvent, phxTarget) => {
          if (phxTarget === "window") {
            const data = this.eventMeta(type, e, targetEl);
            js_default.exec(e, type, phxEvent, view, targetEl, ["push", { data }]);
          }
        }
      );
      this.on("dragover", (e) => e.preventDefault());
      this.on("dragenter", (e) => {
        const dropzone = closestPhxBinding(
          e.target,
          this.binding(PHX_DROP_TARGET)
        );
        if (!dropzone || !(dropzone instanceof HTMLElement)) {
          return;
        }
        if (eventContainsFiles(e)) {
          this.js().addClass(dropzone, PHX_DROP_TARGET_ACTIVE_CLASS);
        }
      });
      this.on("dragleave", (e) => {
        const dropzone = closestPhxBinding(
          e.target,
          this.binding(PHX_DROP_TARGET)
        );
        if (!dropzone || !(dropzone instanceof HTMLElement)) {
          return;
        }
        const rect = dropzone.getBoundingClientRect();
        if (e.clientX <= rect.left || e.clientX >= rect.right || e.clientY <= rect.top || e.clientY >= rect.bottom) {
          this.js().removeClass(dropzone, PHX_DROP_TARGET_ACTIVE_CLASS);
        }
      });
      this.on("drop", (e) => {
        e.preventDefault();
        const dropzone = closestPhxBinding(
          e.target,
          this.binding(PHX_DROP_TARGET)
        );
        if (!dropzone || !(dropzone instanceof HTMLElement)) {
          return;
        }
        this.js().removeClass(dropzone, PHX_DROP_TARGET_ACTIVE_CLASS);
        const dropTargetId = dropzone.getAttribute(this.binding(PHX_DROP_TARGET));
        const dropTarget = dropTargetId && document.getElementById(dropTargetId);
        const files = Array.from(e.dataTransfer.files || []);
        if (!dropTarget || !(dropTarget instanceof HTMLInputElement) || dropTarget.disabled || files.length === 0 || !(dropTarget.files instanceof FileList)) {
          return;
        }
        LiveUploader.trackFiles(dropTarget, files, e.dataTransfer);
        dropTarget.dispatchEvent(new Event("input", { bubbles: true }));
      });
      this.on(PHX_TRACK_UPLOADS, (e) => {
        const uploadTarget = e.target;
        if (!dom_default.isUploadInput(uploadTarget)) {
          return;
        }
        const files = Array.from(e.detail.files || []).filter(
          (f) => f instanceof File || f instanceof Blob
        );
        LiveUploader.trackFiles(uploadTarget, files);
        uploadTarget.dispatchEvent(new Event("input", { bubbles: true }));
      });
    }
    eventMeta(eventName, e, targetEl) {
      const callback = this.metadataCallbacks[eventName];
      return callback ? callback(e, targetEl) : {};
    }
    setPendingLink(href) {
      this.linkRef++;
      this.pendingLink = href;
      this.resetReloadStatus();
      return this.linkRef;
    }
    // anytime we are navigating or connecting, drop reload cookie in case
    // we issue the cookie but the next request was interrupted and the server never dropped it
    resetReloadStatus() {
      browser_default.deleteCookie(PHX_RELOAD_STATUS);
    }
    commitPendingLink(linkRef) {
      if (this.linkRef !== linkRef) {
        return false;
      } else {
        this.href = this.pendingLink;
        this.pendingLink = null;
        return true;
      }
    }
    getHref() {
      return this.href;
    }
    hasPendingLink() {
      return !!this.pendingLink;
    }
    bind(events, callback) {
      for (const event in events) {
        const browserEventName = events[event];
        this.on(browserEventName, (e) => {
          const binding = this.binding(event);
          const windowBinding = this.binding(`window-${event}`);
          const targetPhxEvent = e.target.getAttribute && e.target.getAttribute(binding);
          if (targetPhxEvent) {
            this.debounce(e.target, e, browserEventName, () => {
              this.withinOwners(e.target, (view) => {
                callback(e, event, view, e.target, targetPhxEvent, null);
              });
            });
          } else {
            dom_default.all(document, `[${windowBinding}]`, (el) => {
              const phxEvent = el.getAttribute(windowBinding);
              this.debounce(el, e, browserEventName, () => {
                this.withinOwners(el, (view) => {
                  callback(e, event, view, el, phxEvent, "window");
                });
              });
            });
          }
        });
      }
    }
    bindClicks() {
      this.on("mousedown", (e) => this.clickStartedAtTarget = e.target);
      this.bindClick("click", "click");
    }
    bindClick(eventName, bindingName) {
      const click = this.binding(bindingName);
      window.addEventListener(
        eventName,
        (e) => {
          let target = null;
          if (e.detail === 0)
            this.clickStartedAtTarget = e.target;
          const clickStartedAtTarget = this.clickStartedAtTarget || e.target;
          target = closestPhxBinding(e.target, click);
          this.dispatchClickAway(e, clickStartedAtTarget);
          this.clickStartedAtTarget = null;
          const phxEvent = target && target.getAttribute(click);
          if (!phxEvent) {
            if (dom_default.isNewPageClick(e, window.location)) {
              this.unload();
            }
            return;
          }
          if (target.getAttribute("href") === "#") {
            e.preventDefault();
          }
          if (target.hasAttribute(PHX_REF_SRC)) {
            return;
          }
          this.debounce(target, e, "click", () => {
            this.withinOwners(target, (view) => {
              js_default.exec(e, "click", phxEvent, view, target, [
                "push",
                { data: this.eventMeta("click", e, target) }
              ]);
            });
          });
        },
        false
      );
    }
    dispatchClickAway(e, clickStartedAt) {
      const phxClickAway = this.binding("click-away");
      dom_default.all(document, `[${phxClickAway}]`, (el) => {
        if (!(el.isSameNode(clickStartedAt) || el.contains(clickStartedAt) || // When clicking a link with custom method,
        // phoenix_html triggers a click on a submit button
        // of a hidden form appended to the body. For such cases
        // where the clicked target is hidden, we skip click-away.
        !js_default.isVisible(clickStartedAt))) {
          this.withinOwners(el, (view) => {
            const phxEvent = el.getAttribute(phxClickAway);
            if (js_default.isVisible(el) && js_default.isInViewport(el)) {
              js_default.exec(e, "click", phxEvent, view, el, [
                "push",
                { data: this.eventMeta("click", e, e.target) }
              ]);
            }
          });
        }
      });
    }
    bindNav() {
      if (!browser_default.canPushState()) {
        return;
      }
      if (history.scrollRestoration) {
        history.scrollRestoration = "manual";
      }
      let scrollTimer = null;
      window.addEventListener("scroll", (_e) => {
        clearTimeout(scrollTimer);
        scrollTimer = setTimeout(() => {
          browser_default.updateCurrentState(
            (state) => Object.assign(state, { scroll: window.scrollY })
          );
        }, 100);
      });
      window.addEventListener(
        "popstate",
        (event) => {
          if (!this.registerNewLocation(window.location)) {
            return;
          }
          const { type, backType, id, scroll, position } = event.state || {};
          const href = window.location.href;
          const isForward = position > this.currentHistoryPosition;
          const navType = isForward ? type : backType || type;
          this.currentHistoryPosition = position || 0;
          this.sessionStorage.setItem(
            PHX_LV_HISTORY_POSITION,
            this.currentHistoryPosition.toString()
          );
          dom_default.dispatchEvent(window, "phx:navigate", {
            detail: {
              href,
              patch: navType === "patch",
              pop: true,
              direction: isForward ? "forward" : "backward"
            }
          });
          this.requestDOMUpdate(() => {
            const callback = () => {
              this.maybeScroll(scroll);
            };
            if (this.main.isConnected() && navType === "patch" && id === this.main.id) {
              this.main.pushLinkPatch(event, href, null, callback);
            } else {
              this.replaceMain(href, null, callback);
            }
          });
        },
        false
      );
      window.addEventListener(
        "click",
        (e) => {
          const target = closestPhxBinding(e.target, PHX_LIVE_LINK);
          const type = target && target.getAttribute(PHX_LIVE_LINK);
          if (!type || !this.isConnected() || !this.main || dom_default.wantsNewTab(e)) {
            return;
          }
          const href = target.href instanceof SVGAnimatedString ? target.href.baseVal : target.href;
          const linkState = target.getAttribute(PHX_LINK_STATE);
          e.preventDefault();
          e.stopImmediatePropagation();
          if (this.pendingLink === href) {
            return;
          }
          this.requestDOMUpdate(() => {
            if (type === "patch") {
              this.pushHistoryPatch(e, href, linkState, target);
            } else if (type === "redirect") {
              this.historyRedirect(e, href, linkState, null, target);
            } else {
              throw new Error(
                `expected ${PHX_LIVE_LINK} to be "patch" or "redirect", got: ${type}`
              );
            }
            const phxClick = target.getAttribute(this.binding("click"));
            if (phxClick) {
              this.requestDOMUpdate(() => this.execJS(target, phxClick, "click"));
            }
          });
        },
        false
      );
    }
    maybeScroll(scroll) {
      if (typeof scroll === "number") {
        requestAnimationFrame(() => {
          window.scrollTo(0, scroll);
        });
      }
    }
    dispatchEvent(event, payload = {}) {
      dom_default.dispatchEvent(window, `phx:${event}`, { detail: payload });
    }
    dispatchEvents(events) {
      events.forEach(([event, payload]) => this.dispatchEvent(event, payload));
    }
    withPageLoading(info, callback) {
      dom_default.dispatchEvent(window, "phx:page-loading-start", { detail: info });
      const done = () => dom_default.dispatchEvent(window, "phx:page-loading-stop", { detail: info });
      return callback ? callback(done) : done;
    }
    pushHistoryPatch(e, href, linkState, targetEl) {
      if (!this.isConnected() || !this.main.isMain()) {
        return browser_default.redirect(href);
      }
      this.withPageLoading({ to: href, kind: "patch" }, (done) => {
        this.main.pushLinkPatch(e, href, targetEl, (linkRef) => {
          this.historyPatch(href, linkState, linkRef);
          done();
        });
      });
    }
    historyPatch(href, linkState, linkRef = this.setPendingLink(href)) {
      if (!this.commitPendingLink(linkRef)) {
        return;
      }
      this.currentHistoryPosition++;
      this.sessionStorage.setItem(
        PHX_LV_HISTORY_POSITION,
        this.currentHistoryPosition.toString()
      );
      browser_default.updateCurrentState((state) => ({ ...state, backType: "patch" }));
      browser_default.pushState(
        linkState,
        {
          type: "patch",
          id: this.main.id,
          position: this.currentHistoryPosition
        },
        href
      );
      dom_default.dispatchEvent(window, "phx:navigate", {
        detail: { patch: true, href, pop: false, direction: "forward" }
      });
      this.registerNewLocation(window.location);
    }
    historyRedirect(e, href, linkState, flash, targetEl) {
      const clickLoading = targetEl && e.isTrusted && e.type !== "popstate";
      if (clickLoading) {
        targetEl.classList.add("phx-click-loading");
      }
      if (!this.isConnected() || !this.main.isMain()) {
        return browser_default.redirect(href, flash);
      }
      if (/^\/$|^\/[^\/]+.*$/.test(href)) {
        const { protocol, host } = window.location;
        href = `${protocol}//${host}${href}`;
      }
      const scroll = window.scrollY;
      this.withPageLoading({ to: href, kind: "redirect" }, (done) => {
        this.replaceMain(href, flash, (linkRef) => {
          if (linkRef === this.linkRef) {
            this.currentHistoryPosition++;
            this.sessionStorage.setItem(
              PHX_LV_HISTORY_POSITION,
              this.currentHistoryPosition.toString()
            );
            browser_default.updateCurrentState((state) => ({
              ...state,
              backType: "redirect"
            }));
            browser_default.pushState(
              linkState,
              {
                type: "redirect",
                id: this.main.id,
                scroll,
                position: this.currentHistoryPosition
              },
              href
            );
            dom_default.dispatchEvent(window, "phx:navigate", {
              detail: { href, patch: false, pop: false, direction: "forward" }
            });
            this.registerNewLocation(window.location);
          }
          if (clickLoading) {
            targetEl.classList.remove("phx-click-loading");
          }
          done();
        });
      });
    }
    registerNewLocation(newLocation) {
      const { pathname, search } = this.currentLocation;
      if (pathname + search === newLocation.pathname + newLocation.search) {
        return false;
      } else {
        this.currentLocation = clone(newLocation);
        return true;
      }
    }
    bindForms() {
      let iterations = 0;
      let externalFormSubmitted = false;
      this.on("submit", (e) => {
        const phxSubmit = e.target.getAttribute(this.binding("submit"));
        const phxChange = e.target.getAttribute(this.binding("change"));
        if (!externalFormSubmitted && phxChange && !phxSubmit) {
          externalFormSubmitted = true;
          e.preventDefault();
          this.withinOwners(e.target, (view) => {
            view.disableForm(e.target);
            window.requestAnimationFrame(() => {
              if (dom_default.isUnloadableFormSubmit(e)) {
                this.unload();
              }
              e.target.submit();
            });
          });
        }
      });
      this.on("submit", (e) => {
        const phxEvent = e.target.getAttribute(this.binding("submit"));
        if (!phxEvent) {
          if (dom_default.isUnloadableFormSubmit(e)) {
            this.unload();
          }
          return;
        }
        e.preventDefault();
        e.target.disabled = true;
        this.withinOwners(e.target, (view) => {
          js_default.exec(e, "submit", phxEvent, view, e.target, [
            "push",
            { submitter: e.submitter }
          ]);
        });
      });
      for (const type of ["change", "input"]) {
        this.on(type, (e) => {
          if (e instanceof CustomEvent && (e.target instanceof HTMLInputElement || e.target instanceof HTMLSelectElement || e.target instanceof HTMLTextAreaElement) && e.target.form === void 0) {
            if (e.detail && e.detail.dispatcher) {
              throw new Error(
                `dispatching a custom ${type} event is only supported on input elements inside a form`
              );
            }
            return;
          }
          const phxChange = this.binding("change");
          const input = e.target;
          if (this.blockPhxChangeWhileComposing && e.isComposing) {
            const key = `composition-listener-${type}`;
            if (!dom_default.private(input, key)) {
              dom_default.putPrivate(input, key, true);
              input.addEventListener(
                "compositionend",
                () => {
                  input.dispatchEvent(new Event(type, { bubbles: true }));
                  dom_default.deletePrivate(input, key);
                },
                { once: true }
              );
            }
            return;
          }
          const inputEvent = input.getAttribute(phxChange);
          const formEvent = input.form && input.form.getAttribute(phxChange);
          const phxEvent = inputEvent || formEvent;
          if (!phxEvent) {
            return;
          }
          if (input.type === "number" && input.validity && input.validity.badInput) {
            return;
          }
          const dispatcher = inputEvent ? input : input.form;
          const currentIterations = iterations;
          iterations++;
          const { at, type: lastType } = dom_default.private(input, "prev-iteration") || {};
          if (at === currentIterations - 1 && type === "change" && lastType === "input") {
            return;
          }
          dom_default.putPrivate(input, "prev-iteration", {
            at: currentIterations,
            type
          });
          this.debounce(input, e, type, () => {
            this.withinOwners(dispatcher, (view) => {
              dom_default.putPrivate(input, PHX_HAS_FOCUSED, true);
              js_default.exec(e, "change", phxEvent, view, input, [
                "push",
                { _target: e.target.name, dispatcher }
              ]);
            });
          });
        });
      }
      this.on("reset", (e) => {
        const form = e.target;
        dom_default.resetForm(form);
        const input = Array.from(form.elements).find((el) => el.type === "reset");
        if (input) {
          window.requestAnimationFrame(() => {
            input.dispatchEvent(
              new Event("input", { bubbles: true, cancelable: false })
            );
          });
        }
      });
    }
    debounce(el, event, eventType, callback) {
      if (eventType === "blur" || eventType === "focusout") {
        return callback();
      }
      const phxDebounce = this.binding(PHX_DEBOUNCE);
      const phxThrottle = this.binding(PHX_THROTTLE);
      const defaultDebounce = this.defaults.debounce.toString();
      const defaultThrottle = this.defaults.throttle.toString();
      this.withinOwners(el, (view) => {
        const asyncFilter = () => !view.isDestroyed() && document.body.contains(el);
        dom_default.debounce(
          el,
          event,
          phxDebounce,
          defaultDebounce,
          phxThrottle,
          defaultThrottle,
          asyncFilter,
          () => {
            callback();
          }
        );
      });
    }
    silenceEvents(callback) {
      this.silenced = true;
      callback();
      this.silenced = false;
    }
    on(event, callback) {
      this.boundEventNames.add(event);
      window.addEventListener(event, (e) => {
        if (!this.silenced) {
          callback(e);
        }
      });
    }
    jsQuerySelectorAll(sourceEl, query, defaultQuery) {
      const all = this.domCallbacks.jsQuerySelectorAll;
      return all ? all(sourceEl, query, defaultQuery) : defaultQuery();
    }
  };
  var TransitionSet = class {
    constructor() {
      this.transitions = /* @__PURE__ */ new Set();
      this.promises = /* @__PURE__ */ new Set();
      this.pendingOps = [];
    }
    reset() {
      this.transitions.forEach((timer) => {
        clearTimeout(timer);
        this.transitions.delete(timer);
      });
      this.promises.clear();
      this.flushPendingOps();
    }
    after(callback) {
      if (this.size() === 0) {
        callback();
      } else {
        this.pushPendingOp(callback);
      }
    }
    addTransition(time, onStart, onDone) {
      onStart();
      const timer = setTimeout(() => {
        this.transitions.delete(timer);
        onDone();
        this.flushPendingOps();
      }, time);
      this.transitions.add(timer);
    }
    addAsyncTransition(promise) {
      this.promises.add(promise);
      promise.then(() => {
        this.promises.delete(promise);
        this.flushPendingOps();
      });
    }
    pushPendingOp(op) {
      this.pendingOps.push(op);
    }
    size() {
      return this.transitions.size + this.promises.size;
    }
    flushPendingOps() {
      if (this.size() > 0) {
        return;
      }
      const op = this.pendingOps.shift();
      if (op) {
        op();
        this.flushPendingOps();
      }
    }
  };
  var LiveSocket2 = LiveSocket;

  // ../_build/dev/phoenix-colocated/code_my_spec/CodeMySpecWeb.AppLive.Overview/220_ebyhtrnrzhtaunm523zoflzzq4.js
  var ebyhtrnrzhtaunm523zoflzzq4_default = {
    mounted() {
      if (typeof gtag === "function") {
        gtag("event", "onboarding_panel_viewed");
      }
    }
  };

  // ../_build/dev/phoenix-colocated/code_my_spec/CodeMySpecWeb.ContentLive.Pages.AgenticMarketingWithMcp/28_aofarzdfrh2tw6abjr6eesilxq.js
  var aofarzdfrh2tw6abjr6eesilxq_default = {
    mounted() {
      this._tick = () => {
        const h = document.documentElement;
        const max = h.scrollHeight - h.clientHeight;
        const pct = max > 0 ? h.scrollTop / max * 100 : 0;
        this.el.style.width = pct + "%";
      };
      document.addEventListener("scroll", this._tick, { passive: true });
      this._tick();
    },
    destroyed() {
      document.removeEventListener("scroll", this._tick);
    }
  };

  // ../_build/dev/phoenix-colocated/code_my_spec/CodeMySpecWeb.ContentLive.Pages.Methodology/33_6ahgdk7h4c46cfwebrgyd5apze.js
  var ahgdk7h4c46cfwebrgyd5apze_default = {
    mounted() {
      this._timer = setTimeout(() => {
        if (typeof gtag === "function") {
          gtag("event", "deep_content_read", {
            content_category: document.title,
            page_path: window.location.pathname
          });
        }
      }, 6e4);
    },
    destroyed() {
      clearTimeout(this._timer);
    }
  };

  // ../_build/dev/phoenix-colocated/code_my_spec/CodeMySpecWeb.EpicsLive.Index/251_nzszslijo5tmei5qg2m3qc4vuq.js
  var nzszslijo5tmei5qg2m3qc4vuq_default = {
    mounted() {
      this.sortable = new window.Sortable(this.el, {
        group: "epic-board",
        animation: 150,
        ghostClass: "opacity-40",
        dragClass: "shadow-2xl",
        // `onAdd` fires on the receiving list, so `this.el` is the
        // destination — an epic dropzone, or the unfiled column whose
        // data-epic-id is empty.
        onAdd: (evt) => {
          this.pushEvent("move_story", {
            story_id: evt.item.dataset.storyId,
            epic_id: this.el.dataset.epicId || ""
          });
        }
      });
    },
    destroyed() {
      if (this.sortable) this.sortable.destroy();
    }
  };

  // ../_build/dev/phoenix-colocated/code_my_spec/CodeMySpecWeb.InboxLive/294_cj4x3uj4ctiktb4poxk4enzx6i.js
  var cj4x3uj4ctiktb4poxk4enzx6i_default = {
    mounted() {
      this.scroll();
      this.observer = new MutationObserver(() => this.scroll());
      this.observer.observe(this.el, { childList: true, subtree: true });
    },
    destroyed() {
      this.observer && this.observer.disconnect();
    },
    scroll() {
      this.el.scrollTop = this.el.scrollHeight;
    }
  };

  // ../_build/dev/phoenix-colocated/code_my_spec/CodeMySpecWeb.ProjectLive.Components.OauthCredentials/13_v3f4dccdzkxlr6jbdhwr2xkzge.js
  var v3f4dccdzkxlr6jbdhwr2xkzge_default = {
    mounted() {
      let { to } = this.el.dataset;
      this.el.addEventListener("click", (ev) => {
        ev.preventDefault();
        let text = document.querySelector(to).value;
        navigator.clipboard.writeText(text);
      });
    }
  };

  // ../_build/dev/phoenix-colocated/code_my_spec/CodeMySpecWeb.StoryLive.Scheduler/9_x25zxqk556gkxlbppxx5cnj444.js
  var x25zxqk556gkxlbppxx5cnj444_default = {
    mounted() {
      new window.Sortable(this.el, {
        animation: 150,
        ghostClass: "opacity-50",
        dragClass: "shadow-2xl",
        chosenClass: "ring-2",
        onEnd: (evt) => {
          const storyIds = Array.from(this.el.children).map(
            (item) => item.dataset.storyId
          );
          this.pushEvent("reorder_priorities", {
            story_ids: storyIds
          });
        }
      });
    }
  };

  // ../_build/dev/phoenix-colocated/code_my_spec/CodeMySpecWeb.UserLive.Registration/8_hbumpw2okmo76grzhkftronqty.js
  var hbumpw2okmo76grzhkftronqty_default = {
    mounted() {
      if (typeof gtag === "function") {
        gtag("event", "view_register_page");
      }
      const emailField = this.el.querySelector('input[type="email"]');
      if (emailField) {
        emailField.addEventListener("focus", () => {
          if (typeof gtag === "function") {
            gtag("event", "registration_form_start", { method: "email" });
            gtag("event", "registration_path_chosen", { method: "email" });
          }
        }, { once: true });
      }
      const form = this.el.querySelector("#registration_form");
      if (form) {
        form.addEventListener("submit", () => {
          if (typeof gtag === "function") {
            gtag("event", "registration_path_chosen", { method: "email" });
          }
        }, { once: true });
      }
      this.el.querySelectorAll("[data-registration-method]").forEach((link) => {
        link.addEventListener("click", () => {
          const method = link.dataset.registrationMethod;
          if (typeof gtag === "function") {
            gtag("event", "registration_path_chosen", { method });
            gtag("event", "oauth_" + method + "_clicked");
          }
        }, { once: true });
      });
    }
  };

  // ../_build/dev/phoenix-colocated/code_my_spec/index.js
  var imp_nbxw623t = {};
  imp_nbxw623t["CodeMySpecWeb.AppLive.Overview.SignUpTracking"] = ebyhtrnrzhtaunm523zoflzzq4_default;
  imp_nbxw623t["CodeMySpecWeb.ContentLive.Pages.AgenticMarketingWithMcp.ReadingProgress"] = aofarzdfrh2tw6abjr6eesilxq_default;
  imp_nbxw623t["CodeMySpecWeb.ContentLive.Pages.Methodology.DeepContentRead"] = ahgdk7h4c46cfwebrgyd5apze_default;
  imp_nbxw623t["CodeMySpecWeb.EpicsLive.Index.EpicBoard"] = nzszslijo5tmei5qg2m3qc4vuq_default;
  imp_nbxw623t["CodeMySpecWeb.InboxLive.ChatScroll"] = cj4x3uj4ctiktb4poxk4enzx6i_default;
  imp_nbxw623t["CodeMySpecWeb.ProjectLive.Components.OauthCredentials.CopyToClipboard"] = v3f4dccdzkxlr6jbdhwr2xkzge_default;
  imp_nbxw623t["CodeMySpecWeb.StoryLive.Scheduler.StoryScheduler"] = x25zxqk556gkxlbppxx5cnj444_default;
  imp_nbxw623t["CodeMySpecWeb.UserLive.Registration.ViewRegisterPage"] = hbumpw2okmo76grzhkftronqty_default;

  // js/local_app.js
  var import_Sortable_min = __toESM(require_Sortable_min());

  // js/sigma_graph.js
  var import_graphology_umd_min = __toESM(require_graphology_umd_min());
  var import_sigma_min = __toESM(require_sigma_min());
  window.graphology = window.graphology || import_graphology_umd_min.default;
  window.Sigma = window.Sigma || import_sigma_min.default;
  function themeVar(name) {
    return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  }
  var _normCanvas = null;
  function normalizeColor(c, fallback = "#64748b") {
    if (!c) return fallback;
    const trimmed = String(c).trim();
    if (/^#[0-9a-f]{3,8}$/i.test(trimmed)) return trimmed;
    if (!_normCanvas) {
      _normCanvas = document.createElement("canvas");
      _normCanvas.width = 1;
      _normCanvas.height = 1;
    }
    const ctx = _normCanvas.getContext("2d");
    try {
      ctx.clearRect(0, 0, 1, 1);
      ctx.fillStyle = trimmed;
      ctx.fillRect(0, 0, 1, 1);
      const [r, g, b, a] = ctx.getImageData(0, 0, 1, 1).data;
      if (a === 0) return fallback;
      const hex = "#" + [r, g, b].map((v) => v.toString(16).padStart(2, "0")).join("");
      return hex;
    } catch {
      return fallback;
    }
  }
  function themeColors() {
    return {
      base100: normalizeColor(themeVar("--color-base-100"), "#ffffff"),
      base200: normalizeColor(themeVar("--color-base-200"), "#f5f5f5"),
      base300: normalizeColor(themeVar("--color-base-300"), "#e5e5e5"),
      baseContent: normalizeColor(themeVar("--color-base-content"), "#111111"),
      primary: normalizeColor(themeVar("--color-primary"), "#60a5fa"),
      secondary: normalizeColor(themeVar("--color-secondary"), "#818cf8"),
      accent: normalizeColor(themeVar("--color-accent"), "#6366f1"),
      neutral: normalizeColor(themeVar("--color-neutral"), "#64748b"),
      success: normalizeColor(themeVar("--color-success"), "#4ade80"),
      warning: normalizeColor(themeVar("--color-warning"), "#fbbf24"),
      error: normalizeColor(themeVar("--color-error"), "#ef4444")
    };
  }
  function remapColor(hex, t) {
    switch ((hex || "").toLowerCase()) {
      case "#60a5fa":
        return t.primary;
      // satisfied
      case "#4ade80":
        return t.success;
      // actionable
      case "#fbbf24":
        return t.warning;
      // blocked
      case "#64748b":
        return t.neutral;
      // default node / intra-group edge
      case "#818cf8":
        return t.secondary;
      // cross-group edge
      case "#6366f1":
        return t.accent;
      // special edge
      default:
        return hex || t.neutral;
    }
  }
  var SigmaGraph = {
    mounted() {
      this.handleEvent("graph:ready", ({ data, metrics }) => {
        this.lastMetrics = metrics;
        this.updateLoaderText(`Rendering ${data.nodes.length} nodes\u2026`);
        requestAnimationFrame(() => {
          this.clearLoader();
          this.renderGraph(data);
        });
      });
      this.handleEvent("graph:update", ({ data }) => this.applyGraph(data));
      this.handleEvent("graph:error", ({ message }) => this.showError({ message }));
      this.loadAndRender();
    },
    updated() {
      if (this.sigma) {
        this.sigma.kill();
        this.sigma = null;
      }
      this.loadAndRender();
    },
    destroyed() {
      if (this.sigma) {
        this.sigma.kill();
        this.sigma = null;
      }
      this.clearLoader();
      const panel = document.getElementById("graph-debug");
      if (panel) panel.remove();
    },
    loadAndRender() {
      const raw = this.el.dataset.graph;
      if (raw) {
        this.renderGraph(JSON.parse(raw));
        return;
      }
      this.showLoader("Computing requirements graph\u2026");
    },
    showLoader(message) {
      const t = themeColors();
      this.el.innerHTML = `
      <div style="display:flex;flex-direction:column;align-items:center;justify-content:center;height:100%;gap:12px;color:${t.baseContent}">
        <div style="width:40px;height:40px;border:3px solid ${t.base300};border-top-color:${t.primary};border-radius:50%;animation:sigma-spin 0.8s linear infinite"></div>
        <div data-loader-message style="font-size:1rem;font-weight:600">${message}</div>
        <div data-loader-elapsed style="font-size:0.85rem;opacity:0.7;font-family:ui-monospace,monospace">0.0s</div>
        <div style="font-size:0.75rem;opacity:0.5">Large projects can take a while</div>
      </div>
      <style>@keyframes sigma-spin { to { transform: rotate(360deg) } }</style>
    `;
      this.loaderStart = performance.now();
      this.loaderInterval = setInterval(() => {
        const el = this.el.querySelector("[data-loader-elapsed]");
        if (el) {
          const elapsed = ((performance.now() - this.loaderStart) / 1e3).toFixed(1);
          el.textContent = `${elapsed}s`;
        }
      }, 100);
    },
    updateLoaderText(message) {
      const el = this.el.querySelector("[data-loader-message]");
      if (el) el.textContent = message;
    },
    clearLoader() {
      if (this.loaderInterval) {
        clearInterval(this.loaderInterval);
        this.loaderInterval = null;
      }
      this.el.innerHTML = "";
    },
    showError(err) {
      this.clearLoader();
      console.error("[SigmaGraph] failed to fetch graph data:", err);
      const t = themeColors();
      this.el.innerHTML = `
      <div style="display:flex;flex-direction:column;align-items:center;justify-content:center;height:100%;gap:8px;color:${t.baseContent};padding:24px;text-align:center">
        <div style="font-weight:600;color:${t.error}">Failed to load graph</div>
        <div style="font-size:0.85rem;opacity:0.7">${err.message || err}</div>
      </div>
    `;
    },
    renderGraph(data) {
      const t = themeColors();
      if (this.sigma) {
        this.sigma.kill();
        this.sigma = null;
      }
      const graph = new window.graphology.Graph();
      this.graph = graph;
      data.nodes.forEach((n) => {
        if (!graph.hasNode(n.key)) {
          const attrs = { ...n.attributes, color: remapColor(n.attributes.color, t) };
          graph.addNode(n.key, attrs);
        }
      });
      const seenEdges = /* @__PURE__ */ new Set();
      data.edges.forEach((e) => {
        if (!seenEdges.has(e.key) && graph.hasNode(e.source) && graph.hasNode(e.target)) {
          seenEdges.add(e.key);
          const attrs = { ...e.attributes, color: t.baseContent };
          graph.addEdgeWithKey(e.key, e.source, e.target, attrs);
        }
      });
      const container = this.el;
      const SigmaClass = window.Sigma?.default || window.Sigma;
      this.sigma = new SigmaClass(graph, container, {
        renderLabels: true,
        labelColor: { color: t.baseContent },
        labelFont: "Inter, system-ui, sans-serif",
        labelSize: 16,
        labelWeight: "bold",
        hoverRenderer: (context, data2, settings) => {
          const size = data2.size + 4;
          const label = data2.label || "";
          context.font = `bold 14px Inter, system-ui, sans-serif`;
          const textWidth = context.measureText(label).width;
          const padding = 6;
          const boxWidth = textWidth + padding * 2;
          const boxHeight = 20;
          context.fillStyle = t.base200;
          context.strokeStyle = t.primary;
          context.lineWidth = 1.5;
          context.fillRect(data2.x - boxWidth / 2, data2.y - size - boxHeight - 4, boxWidth, boxHeight);
          context.strokeRect(data2.x - boxWidth / 2, data2.y - size - boxHeight - 4, boxWidth, boxHeight);
          context.fillStyle = t.baseContent;
          context.textAlign = "center";
          context.textBaseline = "middle";
          context.fillText(label, data2.x, data2.y - size - boxHeight / 2 - 4);
        },
        defaultEdgeType: "arrow",
        defaultEdgeColor: t.baseContent,
        stagePadding: 80,
        labelRenderedSizeThreshold: 8,
        labelDensity: 0.5,
        labelGridCellSize: 200,
        defaultNodeColor: t.neutral,
        enableEdgeClickEvents: true,
        enableEdgeHoverEvents: true
      });
      if (data.layout === "force") this.runForceLayout(graph);
      const camera = this.sigma.getCamera();
      camera.setState({ ratio: 1.3 });
      let debugPanel = document.getElementById("graph-debug");
      if (!debugPanel) {
        debugPanel = document.createElement("details");
        debugPanel.id = "graph-debug";
        debugPanel.className = "bg-base-200 text-base-content border-t border-base-300";
        debugPanel.style.cssText = "position:fixed;bottom:0;left:0;right:0;max-height:40vh;overflow-y:auto;padding:8px 16px;font-family:ui-monospace,monospace;font-size:11px;z-index:9999";
        debugPanel.innerHTML = `<summary style="cursor:pointer;opacity:0.7;margin-bottom:8px">Graph Debug (${data.nodes.length} nodes, ${data.edges.length} edges)</summary><div id="graph-debug-metrics" style="margin-bottom:8px"></div><pre id="graph-debug-content" style="margin:0"></pre>`;
        document.body.appendChild(debugPanel);
      }
      const metricsEl = document.getElementById("graph-debug-metrics");
      if (metricsEl && this.lastMetrics) {
        const m = this.lastMetrics;
        const total = Object.entries(m).filter(([k]) => k.endsWith("_ms")).reduce((a, [, v]) => a + v, 0);
        const rows = Object.entries(m).map(([k, v]) => `  ${k.padEnd(22)} ${v}${k.endsWith("_ms") ? "ms" : ""}`).join("\n");
        metricsEl.innerHTML = `<pre style="margin:0;color:inherit">METRICS (total ${total}ms):
${rows}</pre>`;
      }
      const debugContent = document.getElementById("graph-debug-content");
      const edgeList = data.edges.map((e) => `${e.source}  \u2192  ${e.target}`).join("\n");
      debugContent.textContent = `EDGES:
${edgeList}

NODES:
${data.nodes.map((n) => `${n.key}  (${n.attributes.label})`).join("\n")}`;
      this.sigma.on("clickNode", ({ node }) => {
        const attrs = graph.getNodeAttributes(node);
        const inEdges = [];
        const outEdges = [];
        graph.forEachEdge((edge, edgeAttrs, source, target) => {
          if (target === node) inEdges.push({ edge, from: source });
          if (source === node) outEdges.push({ edge, to: target });
        });
        const panel = document.getElementById("graph-debug");
        if (!panel) return;
        panel.open = true;
        const inHtml = inEdges.map((e) => `  \u2190 ${e.from}`).join("\n");
        const outHtml = outEdges.map((e) => `  \u2192 ${e.to}`).join("\n");
        const content = document.getElementById("graph-debug-content");
        content.innerHTML = `<strong>${node}</strong>  (${attrs.label || ""})
<span style="color:${t.primary}">IN (${inEdges.length}):</span>
${inHtml || "  (none)"}
<span style="color:${t.success}">OUT (${outEdges.length}):</span>
${outHtml || "  (none)"}`;
      });
      this.sigma.on("clickEdge", ({ edge }) => {
        const source = graph.source(edge);
        const target = graph.target(edge);
        const sourceLabel = graph.getNodeAttributes(source).label || source;
        const targetLabel = graph.getNodeAttributes(target).label || target;
        const panel = document.getElementById("graph-debug");
        if (!panel) return;
        panel.open = true;
        const content = document.getElementById("graph-debug-content");
        content.textContent = `EDGE: ${edge}

  FROM: ${source}
        (${sourceLabel})

  TO:   ${target}
        (${targetLabel})`;
      });
      this.sigma.on("enterNode", () => {
        container.style.cursor = "pointer";
      });
      this.sigma.on("leaveNode", () => {
        container.style.cursor = "default";
      });
      this.sigma.on("enterEdge", () => {
        container.style.cursor = "pointer";
      });
      this.sigma.on("leaveEdge", () => {
        container.style.cursor = "default";
      });
    },
    // Targeted merge from a watcher-triggered recompute. Mutates the live
    // graphology graph in place so existing node positions survive — only
    // changed attributes (status/color) update, new nodes are slotted in near
    // their neighbors, and removed nodes/edges drop. No global relayout.
    applyGraph(data) {
      if (!this.graph || !this.sigma) return this.renderGraph(data);
      const t = themeColors();
      const g = this.graph;
      const nextNodes = new Set(data.nodes.map((n) => n.key));
      const nextEdges = new Set(data.edges.map((e) => e.key));
      g.edges().forEach((key) => {
        if (!nextEdges.has(key) && g.hasEdge(key)) g.dropEdge(key);
      });
      g.nodes().forEach((key) => {
        if (!nextNodes.has(key)) g.dropNode(key);
      });
      data.nodes.forEach((n) => {
        const { x, y, ...rest } = n.attributes;
        const attrs = { ...rest, color: remapColor(n.attributes.color, t) };
        if (g.hasNode(n.key)) {
          g.mergeNodeAttributes(n.key, attrs);
        } else {
          g.addNode(n.key, { ...attrs, ...this.placeNewNode(g, n.key, data.edges) });
        }
      });
      const seen = /* @__PURE__ */ new Set();
      data.edges.forEach((e) => {
        if (seen.has(e.key)) return;
        seen.add(e.key);
        if (!g.hasEdge(e.key) && g.hasNode(e.source) && g.hasNode(e.target)) {
          g.addEdgeWithKey(e.key, e.source, e.target, { ...e.attributes, color: t.baseContent });
        }
      });
      this.sigma.refresh();
    },
    placeNewNode(g, key, edges) {
      const placed = [];
      edges.forEach((e) => {
        if (e.source === key && g.hasNode(e.target)) placed.push(e.target);
        if (e.target === key && g.hasNode(e.source)) placed.push(e.source);
      });
      if (placed.length === 0) return { x: (Math.random() - 0.5) * 10, y: (Math.random() - 0.5) * 10 };
      let x = 0, y = 0;
      placed.forEach((n) => {
        const a = g.getNodeAttributes(n);
        x += a.x || 0;
        y += a.y || 0;
      });
      return { x: x / placed.length + (Math.random() - 0.5) * 2, y: y / placed.length + (Math.random() - 0.5) * 2 };
    },
    runForceLayout(graph) {
      const iterations = 300;
      const repulsion = 5e4;
      const attraction = 5e-3;
      const damping = 0.85;
      const nodes = graph.nodes();
      const vel = {};
      nodes.forEach((n) => {
        vel[n] = { vx: 0, vy: 0 };
      });
      for (let i = 0; i < iterations; i++) {
        for (let a = 0; a < nodes.length; a++) {
          const na = nodes[a];
          const pa = graph.getNodeAttributes(na);
          for (let b = a + 1; b < nodes.length; b++) {
            const nb = nodes[b];
            const pb = graph.getNodeAttributes(nb);
            const dx = pa.x - pb.x;
            const dy = pa.y - pb.y;
            const dist = Math.sqrt(dx * dx + dy * dy) || 1;
            const force = repulsion / (dist * dist);
            const fx = dx / dist * force;
            const fy = dy / dist * force;
            vel[na].vx += fx;
            vel[na].vy += fy;
            vel[nb].vx -= fx;
            vel[nb].vy -= fy;
          }
        }
        graph.forEachEdge((edge, attrs, source, target) => {
          const pa = graph.getNodeAttributes(source);
          const pb = graph.getNodeAttributes(target);
          const dx = pb.x - pa.x;
          const dy = pb.y - pa.y;
          const dist = Math.sqrt(dx * dx + dy * dy) || 1;
          const force = dist * attraction;
          const fx = dx / dist * force;
          const fy = dy / dist * force;
          vel[source].vx += fx;
          vel[source].vy += fy;
          vel[target].vx -= fx;
          vel[target].vy -= fy;
        });
        nodes.forEach((n) => {
          vel[n].vx *= damping;
          vel[n].vy *= damping;
          const attrs = graph.getNodeAttributes(n);
          graph.setNodeAttribute(n, "x", attrs.x + vel[n].vx);
          graph.setNodeAttribute(n, "y", attrs.y + vel[n].vy);
        });
      }
      this.sigma.refresh();
    }
  };

  // js/local_app.js
  window.Sortable = import_Sortable_min.default;
  var Hooks2 = { SigmaGraph };
  var csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content");
  var liveSocket = new LiveSocket2("/local-live", Socket, {
    params: { _csrf_token: csrfToken },
    hooks: { ...imp_nbxw623t, ...Hooks2 }
  });
  liveSocket.connect();
  window.liveSocket = liveSocket;
  window.addEventListener("phx:download_file", (ev) => {
    const { content, filename, content_type } = ev.detail;
    const blob = new Blob([content], { type: content_type || "text/plain" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename || "download.txt";
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  });
  document.addEventListener("click", (ev) => {
    const btn = ev.target.closest(".copy-btn[data-copy]");
    if (!btn) return;
    const text = btn.getAttribute("data-copy");
    const original = btn.textContent;
    const restore = () => {
      btn.textContent = original;
    };
    const done = () => {
      btn.textContent = "\u2713 Copied";
      setTimeout(restore, 1800);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, () => copyFallback(text, done));
    } else {
      copyFallback(text, done);
    }
  });
  function copyFallback(text, done) {
    const ta = document.createElement("textarea");
    ta.value = text;
    document.body.appendChild(ta);
    ta.select();
    try {
      document.execCommand("copy");
    } catch (_) {
    }
    document.body.removeChild(ta);
    done();
  }
})();
/*! Sortable 1.15.6 - MIT | git://github.com/SortableJS/Sortable.git */
