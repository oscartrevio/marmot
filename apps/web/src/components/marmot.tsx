"use client";

import { useEffect, useState } from "react";

import { mascot } from "@/generated/mascot";
import type { Frame } from "@/lib/marmot";

import { Art } from "./art";

// A blink as mm status's live view does it: half shut, shut, half shut, open.
const BLINK: readonly [Frame, number][] = [
  ["blink", 70],
  ["shut", 90],
  ["blink", 70],
  ["open", 0],
];

/** The marmot, blinking now and then. */
export const Marmot = () => {
  const [frame, setFrame] = useState<Frame>("open");

  useEffect(() => {
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) {
      return;
    }
    let timer: ReturnType<typeof setTimeout>;
    const blink = (step: number) => {
      const [next, hold] = BLINK[step] ?? ["open", 0];
      setFrame(next);
      timer =
        step < BLINK.length - 1
          ? setTimeout(() => blink(step + 1), hold)
          : setTimeout(() => blink(0), 2500 + Math.random() * 3500);
    };
    timer = setTimeout(() => blink(0), 1500);
    return () => clearTimeout(timer);
  }, []);

  return <Art art={mascot[frame]} />;
};
