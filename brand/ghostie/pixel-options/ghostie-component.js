const template = document.createElement("template");

template.innerHTML = `
  <style>
    :host {
      --ghostie-bg: #eceae6;
      --ghostie-grid-line: #d0d0d0;
      --ghostie-white: #f8f9fa;
      --ghostie-shadow: #d1d8e0;
      --ghostie-ink: #1a1a1a;
      --ghostie-phone-body: #2c3e50;
      --ghostie-phone-screen: #3498db;
      --ghostie-red: #ef3349;
      --ghostie-cyan: #00c7ff;
      --ghostie-green: #39d076;
      --ghostie-hat-blue: #2f62bb;
      --ghostie-cap-red: #e93243;
      --ghostie-coffee: #8a5b38;
      --ghostie-steam: #a8764e;
      --pixel-size: 6px;
      --sub-pixel-size: 2px;
      display: inline-block;
      inline-size: calc(var(--pixel-size) * 16);
      block-size: calc(var(--pixel-size) * 16);
      contain: layout style;
      overflow: visible;
    }

    .ghostie-complex {
      position: relative;
      inline-size: calc(var(--pixel-size) * 16);
      block-size: calc(var(--pixel-size) * 16);
      transform-origin: center;
    }

    .ghost-body {
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * 1.55);
      inset-inline-start: calc(var(--pixel-size) * 2.6);
      inline-size: calc(var(--pixel-size) * 10.9);
      block-size: calc(var(--pixel-size) * 12.55);
      background: var(--ghostie-ink);
      clip-path: polygon(
        28% 0,
        72% 0,
        72% 6%,
        82% 6%,
        82% 12%,
        90% 12%,
        90% 21%,
        96% 21%,
        96% 33%,
        100% 33%,
        100% 86%,
        92% 86%,
        92% 100%,
        82% 100%,
        82% 92%,
        72% 92%,
        72% 86%,
        62% 86%,
        62% 100%,
        52% 100%,
        52% 92%,
        42% 92%,
        42% 100%,
        32% 100%,
        32% 86%,
        22% 86%,
        22% 92%,
        14% 92%,
        14% 100%,
        4% 100%,
        4% 86%,
        0 86%,
        0 33%,
        4% 33%,
        4% 21%,
        10% 21%,
        10% 12%,
        18% 12%,
        18% 6%,
        28% 6%
      );
    }

    .ghost-body::before,
    .ghost-body::after {
      content: "";
      position: absolute;
      pointer-events: none;
    }

    .ghost-body::before {
      inset: calc(var(--pixel-size) * .78);
      background: var(--ghostie-white);
      clip-path: polygon(
        24% 0,
        76% 0,
        76% 7%,
        86% 7%,
        86% 16%,
        95% 16%,
        95% 31%,
        100% 31%,
        100% 81%,
        90% 81%,
        90% 100%,
        80% 100%,
        80% 90%,
        68% 90%,
        68% 82%,
        59% 82%,
        59% 100%,
        48% 100%,
        48% 90%,
        39% 90%,
        39% 100%,
        28% 100%,
        28% 82%,
        17% 82%,
        17% 91%,
        7% 91%,
        7% 100%,
        0 100%,
        0 30%,
        5% 30%,
        5% 16%,
        14% 16%,
        14% 7%,
        24% 7%
      );
      z-index: 1;
    }

    .ghost-body::after {
      inset-block-start: calc(var(--pixel-size) * 1.25);
      inset-inline-start: calc(var(--pixel-size) * 1.05);
      inline-size: calc(var(--pixel-size) * 1.45);
      block-size: calc(var(--pixel-size) * 9.8);
      background: var(--ghostie-shadow);
      clip-path: polygon(
        55% 0,
        100% 0,
        100% 9%,
        67% 9%,
        67% 19%,
        39% 19%,
        39% 83%,
        0 83%,
        0 100%,
        83% 100%,
        83% 91%,
        55% 91%
      );
      opacity: .98;
      z-index: 2;
    }

    .ghost-eye {
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * 5.55);
      inline-size: calc(var(--pixel-size) * 1.25);
      block-size: calc(var(--pixel-size) * 1.8);
      background: var(--ghostie-ink);
      border-radius: 1px;
    }

    .ghost-eye.left {
      inset-inline-start: calc(var(--pixel-size) * 6);
    }

    .ghost-eye.right {
      inset-inline-start: calc(var(--pixel-size) * 9.75);
    }

    .ghost-mouth {
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * 8.25);
      inset-inline-start: calc(var(--pixel-size) * 7.55);
      inline-size: calc(var(--pixel-size) * 1.85);
      block-size: calc(var(--sub-pixel-size) * 2);
      background: var(--ghostie-ink);
      border-radius: 1px;
    }

    :host([mood="happy"]) .ghost-mouth,
    :host([pose="wave"]) .ghost-mouth {
      inset-block-start: calc(var(--pixel-size) * 7.8);
      block-size: calc(var(--pixel-size) * 1);
      border-radius: 0 0 10px 10px;
    }

    .ghost-arm,
    .ghost-phone,
    .wave-arm,
    .thought-bubble,
    .thinking-hand,
    .confused-mark,
    .angry-artifacts,
    .headphones,
    .wrap-ribbon,
    .top-hat,
    .cap,
    .coffee-cup,
    .text-bubble,
    .sleep-marks {
      display: none;
    }

    :host([prop="phone"]) .ghost-arm,
    :host([prop="phone"]) .ghost-phone {
      display: block;
    }

    .ghost-arm {
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * 7);
      inset-inline-start: calc(var(--pixel-size) * 12.1);
      inline-size: calc(var(--pixel-size) * 2);
      block-size: calc(var(--pixel-size) * 1.5);
      background: var(--ghostie-white);
      border: calc(var(--pixel-size) * .8) solid var(--ghostie-ink);
      border-inline-start: 0;
      border-radius: 0 10px 10px 0;
    }

    .ghost-phone {
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * 5);
      inset-inline-start: calc(var(--pixel-size) * 13.6);
      inline-size: calc(var(--sub-pixel-size) * 8);
      block-size: calc(var(--sub-pixel-size) * 14);
      background: var(--ghostie-phone-body);
      border: calc(var(--sub-pixel-size) * 1.5) solid var(--ghostie-ink);
      border-radius: 3px;
      transform: rotate(13deg);
    }

    .phone-screen {
      position: absolute;
      inset-block-start: calc(var(--sub-pixel-size) * 1.5);
      inset-inline-start: calc(var(--sub-pixel-size) * 1);
      inline-size: calc(var(--sub-pixel-size) * 6);
      block-size: calc(var(--sub-pixel-size) * 9);
      background: var(--ghostie-phone-screen);
    }

    .phone-button {
      position: absolute;
      inset-block-end: calc(var(--sub-pixel-size) * 1);
      inset-inline-start: 50%;
      inline-size: calc(var(--sub-pixel-size) * 2);
      block-size: calc(var(--sub-pixel-size) * 2);
      background: var(--ghostie-ink);
      border-radius: 50%;
      transform: translateX(-50%);
    }

    :host([pose="wave"]) .wave-arm {
      display: block;
    }

    .wave-arm {
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * 5.8);
      inset-inline-start: calc(var(--pixel-size) * 12.1);
      inline-size: calc(var(--pixel-size) * 3.4);
      block-size: calc(var(--pixel-size) * 1.4);
      background: var(--ghostie-white);
      border: calc(var(--pixel-size) * .7) solid var(--ghostie-ink);
      border-inline-start: 0;
      border-radius: 0 10px 10px 0;
      transform: rotate(-36deg);
      transform-origin: left center;
    }

    :host([pose="thinking"]) .thought-bubble {
      display: block;
    }

    :host([pose="thinking"]) .thinking-hand {
      display: block;
    }

    :host([pose="thinking"]) .ghost-mouth {
      inline-size: calc(var(--pixel-size) * 1.3);
      inset-inline-start: calc(var(--pixel-size) * 8.2);
      border-radius: 10px;
    }

    .thought-bubble {
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * 1.3);
      inset-inline-start: calc(var(--pixel-size) * 12.3);
      inline-size: calc(var(--pixel-size) * 1.25);
      block-size: calc(var(--pixel-size) * 1.25);
      border: calc(var(--sub-pixel-size) * 1.2) solid var(--ghostie-phone-screen);
      border-radius: 50%;
      background: var(--ghostie-white);
      box-shadow:
        calc(var(--pixel-size) * 1.1) calc(var(--pixel-size) * -1) 0 calc(var(--sub-pixel-size) * .5) var(--ghostie-white),
        calc(var(--pixel-size) * 1.1) calc(var(--pixel-size) * -1) 0 calc(var(--sub-pixel-size) * 1.6) var(--ghostie-phone-screen);
    }

    .thinking-hand {
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * 8.8);
      inset-inline-start: calc(var(--pixel-size) * 6.5);
      inline-size: calc(var(--pixel-size) * 2.4);
      block-size: calc(var(--pixel-size) * 2.2);
      border: calc(var(--sub-pixel-size) * 1.4) solid var(--ghostie-ink);
      border-inline-start: 0;
      border-block-start: 0;
      border-radius: 0 0 12px 0;
      transform: rotate(-18deg);
    }

    :host([mood="confused"]) .ghost-eye.left {
      inline-size: calc(var(--pixel-size) * 1.1);
      block-size: calc(var(--sub-pixel-size) * 1.5);
      border-radius: 0;
      transform: translateY(calc(var(--pixel-size) * .6)) rotate(25deg);
    }

    :host([mood="confused"]) .ghost-mouth {
      inline-size: calc(var(--pixel-size) * 1.4);
      inset-inline-start: calc(var(--pixel-size) * 8);
      border-radius: 10px;
    }

    :host([mood="confused"]) .confused-mark {
      display: block;
    }

    .confused-mark {
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * 2.7);
      inset-inline-start: calc(var(--pixel-size) * 5.2);
      inline-size: calc(var(--sub-pixel-size) * 2);
      block-size: calc(var(--sub-pixel-size) * 2);
      background: var(--ghostie-ink);
      border-radius: 50%;
      box-shadow:
        calc(var(--sub-pixel-size) * -1.8) calc(var(--sub-pixel-size) * -1.6) 0 var(--ghostie-ink),
        calc(var(--sub-pixel-size) * -2.6) calc(var(--sub-pixel-size) * -3.2) 0 var(--ghostie-ink);
    }

    :host([mood="angry"]) .ghost-eye {
      inline-size: calc(var(--pixel-size) * 2);
      block-size: calc(var(--sub-pixel-size) * 2);
      border-radius: 0;
    }

    :host([mood="angry"]) .ghost-eye.left {
      transform: rotate(38deg) translateY(calc(var(--pixel-size) * .4));
    }

    :host([mood="angry"]) .ghost-eye.right {
      transform: rotate(-38deg) translateY(calc(var(--pixel-size) * .4));
    }

    :host([mood="angry"]) .ghost-mouth {
      inset-block-start: calc(var(--pixel-size) * 8.9);
      inline-size: calc(var(--pixel-size) * 2.2);
      border-radius: 10px 10px 0 0;
    }

    :host([mood="angry"]) .angry-artifacts {
      display: block;
    }

    .angry-artifacts {
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * 4.5);
      inset-inline-start: calc(var(--pixel-size) * 1);
      inline-size: calc(var(--sub-pixel-size) * 5);
      block-size: calc(var(--sub-pixel-size) * 1.5);
      background: var(--ghostie-red);
      box-shadow:
        calc(var(--pixel-size) * -1) calc(var(--pixel-size) * 3.2) 0 0 var(--ghostie-red),
        calc(var(--pixel-size) * 11.3) calc(var(--pixel-size) * 1.1) 0 0 var(--ghostie-red),
        calc(var(--pixel-size) * 12.2) calc(var(--pixel-size) * 5.2) 0 0 var(--ghostie-cyan),
        calc(var(--pixel-size) * .7) calc(var(--pixel-size) * 8.5) 0 0 var(--ghostie-cyan);
    }

    :host([accessory="headphones"]) .headphones {
      display: block;
    }

    .headphones::before {
      content: "";
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * 3.35);
      inset-inline-start: calc(var(--pixel-size) * 4.1);
      inline-size: calc(var(--pixel-size) * 8);
      block-size: calc(var(--pixel-size) * 3.8);
      border: calc(var(--sub-pixel-size) * 2) solid var(--ghostie-ink);
      border-block-end: 0;
      border-radius: 18px 18px 0 0;
    }

    .headphones::after {
      content: "";
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * 6.4);
      inset-inline-start: calc(var(--pixel-size) * 2.4);
      inline-size: calc(var(--pixel-size) * 2);
      block-size: calc(var(--pixel-size) * 3.8);
      background: var(--ghostie-green);
      border: calc(var(--sub-pixel-size) * 2) solid var(--ghostie-ink);
      border-radius: 4px;
      box-shadow: calc(var(--pixel-size) * 9.1) 0 0 0 var(--ghostie-green), calc(var(--pixel-size) * 9.1) 0 0 calc(var(--sub-pixel-size) * 2) var(--ghostie-ink);
    }

    :host([accessory="ribbon"]) .wrap-ribbon {
      display: block;
    }

    .wrap-ribbon {
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * 7.8);
      inset-inline-start: calc(var(--pixel-size) * -.8);
      inline-size: calc(var(--pixel-size) * 17);
      block-size: calc(var(--sub-pixel-size) * 2);
      background: var(--ghostie-red);
      box-shadow:
        calc(var(--pixel-size) * -1.2) calc(var(--pixel-size) * -1) 0 0 var(--ghostie-red),
        calc(var(--pixel-size) * 1.2) calc(var(--pixel-size) * 1.2) 0 0 var(--ghostie-red),
        calc(var(--pixel-size) * 11) calc(var(--pixel-size) * -1.15) 0 0 var(--ghostie-red),
        calc(var(--pixel-size) * 13) calc(var(--pixel-size) * 1.1) 0 0 var(--ghostie-red);
    }

    :host([accessory="top-hat"]) .top-hat {
      display: block;
    }

    .top-hat {
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * .6);
      inset-inline-start: calc(var(--pixel-size) * 5.1);
      inline-size: calc(var(--pixel-size) * 6.2);
      block-size: calc(var(--pixel-size) * 1.1);
      background: var(--ghostie-ink);
      border-radius: 2px;
    }

    .top-hat::before {
      content: "";
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * -3.2);
      inset-inline-start: calc(var(--pixel-size) * 1.2);
      inline-size: calc(var(--pixel-size) * 3.8);
      block-size: calc(var(--pixel-size) * 3.2);
      background:
        linear-gradient(to bottom, var(--ghostie-hat-blue) 0 72%, var(--ghostie-phone-screen) 72% 100%);
      border: calc(var(--sub-pixel-size) * 1.6) solid var(--ghostie-ink);
      border-block-end: 0;
      border-radius: 2px 2px 0 0;
    }

    :host([accessory="cap"]) .cap {
      display: block;
    }

    .cap {
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * 1.7);
      inset-inline-start: calc(var(--pixel-size) * 4.8);
      inline-size: calc(var(--pixel-size) * 6.8);
      block-size: calc(var(--pixel-size) * 1.8);
      background: var(--ghostie-cap-red);
      border: calc(var(--sub-pixel-size) * 1.7) solid var(--ghostie-ink);
      border-block-end: 0;
      border-radius: 8px 8px 0 0;
    }

    .cap::after {
      content: "";
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * 1.25);
      inset-inline-start: calc(var(--pixel-size) * 4.2);
      inline-size: calc(var(--pixel-size) * 4.5);
      block-size: calc(var(--pixel-size) * .75);
      background: var(--ghostie-cap-red);
      border: calc(var(--sub-pixel-size) * 1.5) solid var(--ghostie-ink);
      border-inline-start: 0;
      border-radius: 0 4px 4px 0;
    }

    :host([prop="coffee"]) .ghost-arm,
    :host([prop="coffee"]) .coffee-cup {
      display: block;
    }

    :host([prop="coffee"]) .ghost-arm {
      inset-block-start: calc(var(--pixel-size) * 8);
    }

    .coffee-cup {
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * 6.1);
      inset-inline-start: calc(var(--pixel-size) * 13.2);
      inline-size: calc(var(--pixel-size) * 2.4);
      block-size: calc(var(--pixel-size) * 4.1);
      background:
        linear-gradient(to bottom, #ead5b5 0 24%, var(--ghostie-coffee) 24% 100%);
      border: calc(var(--sub-pixel-size) * 1.7) solid var(--ghostie-ink);
      border-radius: 4px;
    }

    .coffee-cup::before {
      content: "";
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * 1.1);
      inset-inline-start: calc(var(--pixel-size) * 2.1);
      inline-size: calc(var(--pixel-size) * .9);
      block-size: calc(var(--pixel-size) * 1.3);
      border: calc(var(--sub-pixel-size) * 1.3) solid var(--ghostie-ink);
      border-inline-start: 0;
      border-radius: 0 8px 8px 0;
    }

    .coffee-cup::after {
      content: "";
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * -3.2);
      inset-inline-start: calc(var(--pixel-size) * .35);
      inline-size: calc(var(--sub-pixel-size) * 2);
      block-size: calc(var(--pixel-size) * 2);
      border-inline-end: calc(var(--sub-pixel-size) * 1.4) solid var(--ghostie-steam);
      border-radius: 50%;
      box-shadow:
        calc(var(--pixel-size) * .9) calc(var(--sub-pixel-size) * -1) 0 calc(var(--sub-pixel-size) * -.2) var(--ghostie-steam),
        calc(var(--pixel-size) * 1.45) calc(var(--sub-pixel-size) * 1.2) 0 calc(var(--sub-pixel-size) * -.2) var(--ghostie-steam);
    }

    :host([pose="text"]) .text-bubble {
      display: block;
    }

    .text-bubble {
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * .8);
      inset-inline-start: calc(var(--pixel-size) * 5.9);
      inline-size: calc(var(--pixel-size) * 5);
      block-size: calc(var(--pixel-size) * 2.5);
      background: var(--ghostie-white);
      border: calc(var(--sub-pixel-size) * 1.5) solid var(--ghostie-ink);
      border-radius: 4px;
    }

    .text-bubble::before {
      content: "";
      position: absolute;
      inset-block-end: calc(var(--sub-pixel-size) * -2.2);
      inset-inline-start: calc(var(--pixel-size) * .9);
      inline-size: calc(var(--pixel-size) * .9);
      block-size: calc(var(--pixel-size) * .9);
      background: var(--ghostie-white);
      border-inline-end: calc(var(--sub-pixel-size) * 1.5) solid var(--ghostie-ink);
      border-block-end: calc(var(--sub-pixel-size) * 1.5) solid var(--ghostie-ink);
      transform: rotate(45deg);
    }

    .text-bubble::after {
      content: "";
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * .9);
      inset-inline-start: calc(var(--pixel-size) * 1);
      inline-size: calc(var(--sub-pixel-size) * 2);
      block-size: calc(var(--sub-pixel-size) * 2);
      background: var(--ghostie-ink);
      border-radius: 50%;
      box-shadow:
        calc(var(--pixel-size) * 1.25) 0 0 var(--ghostie-ink),
        calc(var(--pixel-size) * 2.5) 0 0 var(--ghostie-ink);
    }

    :host([mood="sleepy"]) .ghost-eye {
      block-size: calc(var(--sub-pixel-size) * 1.5);
      border-radius: 0;
      transform: translateY(calc(var(--pixel-size) * .4));
    }

    :host([mood="sleepy"]) .ghost-mouth {
      inline-size: calc(var(--pixel-size) * 1.2);
      block-size: calc(var(--pixel-size) * 1.2);
      border-radius: 50%;
    }

    :host([mood="sleepy"]) .sleep-marks {
      display: block;
    }

    :host([mood="sleepy"]) .ghostie-complex {
      transform: rotate(90deg) translateY(calc(var(--pixel-size) * .5));
    }

    .sleep-marks {
      position: absolute;
      inset-block-start: calc(var(--pixel-size) * .8);
      inset-inline-start: calc(var(--pixel-size) * 11.8);
      inline-size: calc(var(--pixel-size) * 1.7);
      block-size: calc(var(--sub-pixel-size) * 1.5);
      background: var(--ghostie-ink);
      transform: rotate(-90deg);
      box-shadow:
        calc(var(--pixel-size) * 1.2) calc(var(--pixel-size) * -1.3) 0 0 var(--ghostie-ink),
        calc(var(--pixel-size) * 2.3) calc(var(--pixel-size) * -2.7) 0 0 var(--ghostie-ink);
    }

    :host(.ghostie-float) .ghostie-complex {
      animation: ghostie-float 2s ease-in-out infinite;
    }

    :host(.ghostie-glitch) .ghostie-complex {
      animation: ghostie-glitch 320ms steps(2, end) infinite;
    }

    @keyframes ghostie-float {
      0%,
      100% {
        transform: translateY(0);
      }

      50% {
        transform: translateY(-4px);
      }
    }

    @keyframes ghostie-glitch {
      0%,
      100% {
        filter: none;
        transform: translateX(0);
      }

      20% {
        filter: drop-shadow(2px 0 var(--ghostie-red)) drop-shadow(-2px 0 var(--ghostie-cyan));
        transform: translateX(-2px);
      }

      45% {
        filter: drop-shadow(-3px 0 var(--ghostie-red)) drop-shadow(3px 0 var(--ghostie-cyan));
        transform: translateX(3px);
      }

      70% {
        filter: drop-shadow(1px 0 var(--ghostie-red)) drop-shadow(-1px 0 var(--ghostie-cyan));
        transform: translateX(-1px);
      }
    }

    @media (prefers-reduced-motion: reduce) {
      :host(.ghostie-float) .ghostie-complex,
      :host(.ghostie-glitch) .ghostie-complex {
        animation: none;
      }
    }
  </style>

  <div class="ghostie-complex" part="character">
    <div class="ghost-body"></div>
    <div class="ghost-eye left"></div>
    <div class="ghost-eye right"></div>
    <div class="ghost-mouth"></div>
    <div class="ghost-arm"></div>
    <div class="wave-arm"></div>
    <div class="thought-bubble"></div>
    <div class="thinking-hand"></div>
    <div class="confused-mark"></div>
    <div class="angry-artifacts"></div>
    <div class="headphones"></div>
    <div class="wrap-ribbon"></div>
    <div class="top-hat"></div>
    <div class="cap"></div>
    <div class="coffee-cup"></div>
    <div class="text-bubble"></div>
    <div class="sleep-marks"></div>
    <div class="ghost-phone">
      <div class="phone-screen"></div>
      <div class="phone-button"></div>
    </div>
  </div>
`;

if (!customElements.get("ghostie-character")) {
  customElements.define(
    "ghostie-character",
    class GhostieCharacter extends HTMLElement {
      connectedCallback() {
        if (!this.shadowRoot) {
          this.attachShadow({ mode: "open" }).append(template.content.cloneNode(true));
        }

        if (!this.hasAttribute("role")) {
          this.setAttribute("role", "img");
        }

        if (!this.hasAttribute("aria-label")) {
          this.setAttribute("aria-label", "Ghostie pseudo-8bit character");
        }
      }
    },
  );
}
