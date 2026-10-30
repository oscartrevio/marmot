"use client";

import { useRef, useState } from "react";

import { COMMAND } from "@/lib/marmot";

type CopyState = "idle" | "copied" | "failed";

const ANNOUNCEMENTS: Record<CopyState, string> = {
  copied: "Install command copied",
  failed: "Couldn't copy. Select the command and copy it manually.",
  idle: "",
};

const ICON =
  "absolute inset-0 transition-[opacity,filter,scale] duration-300 ease-out motion-reduce:scale-100 motion-reduce:blur-none";
const SHOWN = "scale-100 opacity-100 blur-0";
const HIDDEN = "scale-[0.25] opacity-0 blur-sm";

/** The install command in a card, with a button that copies it. */
export const InstallCommand = () => {
  const [state, setState] = useState<CopyState>("idle");
  const timeout = useRef<ReturnType<typeof setTimeout>>(undefined);
  const copied = state === "copied";

  const copy = async () => {
    clearTimeout(timeout.current);
    try {
      await navigator.clipboard.writeText(COMMAND);
      setState("copied");
    } catch {
      setState("failed");
    }
    timeout.current = setTimeout(() => setState("idle"), 2500);
  };

  return (
    <div className="border-shadow hover:hover-border-shadow mono flex w-full items-center gap-[1.2em] rounded-xl bg-white p-[0.6em] font-mono transition-shadow duration-200 ease-out">
      <div className="command no-scrollbar flex min-w-0 flex-1 overflow-x-auto">
        <span
          aria-hidden="true"
          className="whitespace-pre text-(--gray-a11) select-none"
        >
          {"$ "}
        </span>
        <code className="whitespace-pre text-(--gray-a12)">{`${COMMAND}  `}</code>
      </div>
      <button
        aria-label="Copy install command"
        className="group relative size-[1.2em] shrink-0 cursor-pointer touch-manipulation rounded-sm focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-(--gray-a11)"
        onClick={copy}
        type="button"
      >
        <svg
          aria-hidden="true"
          className={`${ICON} text-(--green-a10) ${copied ? SHOWN : HIDDEN}`}
          fill="currentColor"
          viewBox="0 0 640 640"
        >
          <path d="M320 576C178.6 576 64 461.4 64 320C64 178.6 178.6 64 320 64C461.4 64 576 178.6 576 320C576 461.4 461.4 576 320 576zM438 209.7C427.3 201.9 412.3 204.3 404.5 215L285.1 379.2L233 327.1C223.6 317.7 208.4 317.7 199.1 327.1C189.8 336.5 189.7 351.7 199.1 361L271.1 433C276.1 438 282.9 440.5 289.9 440C296.9 439.5 303.3 435.9 307.4 430.2L443.3 243.2C451.1 232.5 448.7 217.5 438 209.7z" />
        </svg>
        <svg
          aria-hidden="true"
          className={`${ICON} text-(--gray-a11) group-hover:text-(--gray-a12) ${copied ? HIDDEN : SHOWN}`}
          fill="currentColor"
          viewBox="0 0 640 640"
        >
          <path d="M352 512L128 512L128 288L176 288L176 224L128 224C92.7 224 64 252.7 64 288L64 512C64 547.3 92.7 576 128 576L352 576C387.3 576 416 547.3 416 512L416 464L352 464L352 512zM288 416L512 416C547.3 416 576 387.3 576 352L576 128C576 92.7 547.3 64 512 64L288 64C252.7 64 224 92.7 224 128L224 352C224 387.3 252.7 416 288 416z" />
        </svg>
      </button>
      <output className="sr-only">{ANNOUNCEMENTS[state]}</output>
    </div>
  );
};
