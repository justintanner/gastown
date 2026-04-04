// Gas Town OpenCode plugin: hooks SessionStart/Compaction via events.
// Injects gt prime context into the system prompt via experimental.chat.system.transform.
// Logging is opt-in via GT_OPENCODE_DEBUG — stderr writes corrupt the TUI redraw
// (especially high-frequency events like message.part.delta during streaming).
const log = process.env.GT_OPENCODE_DEBUG
  ? (...args) => console.error("[gastown]", ...args)
  : () => {};
export const server = async ({ $, directory }) => {
  log("plugin loaded, directory:", directory);
  const role = (process.env.GT_ROLE || "").toLowerCase();
  log("role:", role || "(none)");
  const autonomousRoles = new Set(["polecat", "witness", "refinery", "deacon"]);
  let didInit = false;

  // Promise-based context loading ensures the system transform hook can
  // await the result even if session.created hasn't resolved yet.
  let primePromise = null;
  const captureRun = async (cmd) => {
    try {
      // .text() captures stdout as a string and suppresses terminal echo.
      return await $`/bin/sh -lc ${cmd}`.cwd(directory).text();
    } catch (err) {
      console.error(`[gastown] ${cmd} failed`, err?.message || err);
      return "";
    }
  };

  const loadPrime = async () => {
    let context = await captureRun("gt prime");
    if (autonomousRoles.has(role)) {
      const mail = await captureRun("gt mail check --inject");
      if (mail) {
        context += "\n" + mail;
      }
    }
    // NOTE: session-started nudge to deacon removed — it interrupted
    // the deacon's await-signal backoff. Deacon wakes on beads activity.
    return context;
  };

  return {
    event: async ({ event }) => {
      // Don't log every event — message.part.delta fires per streaming token
      // and floods the TUI. Log only the ones we actually handle.
      if (event?.type === "session.created") {
        log("event: session.created");
        if (didInit) return;
        didInit = true;
        // Start loading prime context early; system.transform will await it.
        primePromise = loadPrime();
      }
      if (event?.type === "session.compacted") {
        log("event: session.compacted");
        // Reset so next system.transform gets fresh context.
        primePromise = loadPrime();
      }
      if (event?.type === "session.deleted") {
        log("event: session.deleted");
        const sessionID = event.properties?.info?.id;
        if (sessionID) {
          await $`gt costs record --session ${sessionID}`.catch(() => {});
        }
      }
    },
    "experimental.chat.system.transform": async (input, output) => {
      log("system.transform called, sessionID:", input.sessionID);
      // If session.created hasn't fired yet, start loading now.
      if (!primePromise) {
        primePromise = loadPrime();
      }
      const context = await primePromise;
      if (context) {
        output.system.push(context);
      } else {
        // Reset so next transform retries instead of pushing empty forever.
        primePromise = null;
      }

    },
    // Mirrors Claude's UserPromptSubmit hook: fires on every user prompt,
    // drains both mail and the nudge queue via gt mail check --inject.
    "chat.message": async ({ sessionID }, output) => {
      log("chat.message, role:", role, "sessionID:", sessionID);
      if (!autonomousRoles.has(role)) return;
      const mail = await captureRun("gt mail check --inject");
      if (mail) {
        output.parts.push({
          type: "text",
          text: mail,
        });
      }
    },
    "experimental.session.compacting": async ({ sessionID }, output) => {
      log("session.compacting, sessionID:", sessionID);
      const roleDisplay = role || "unknown";
      output.context.push(`
## Gas Town Multi-Agent System

**After Compaction:** Run \`gt prime\` to restore full context.
**Check Hook:** \`gt hook\` - if work present, execute immediately (GUPP).
**Role:** ${roleDisplay}
`);
    },
  };
};
