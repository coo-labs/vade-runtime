// events-dump.js — operator-mediated dump tool for claude.ai/v1/sessions/<id>/events.
//
// Origin: coo-labs/coo-console#28 (events-API discovery during briefing-039 Phase 5).
//
// Usage:
//   1. Open claude.ai in a logged-in browser tab.
//   2. Open DevTools (F12) → Console.
//   3. Paste this entire file's contents.
//   4. Call dumpEvents(['session_01abc...', 'session_01def...']) with the session IDs.
//   5. Save the returned blob:
//        const data = await dumpEvents([...]);
//        const blob = new Blob([JSON.stringify(data)], {type:'application/json'});
//        const url = URL.createObjectURL(blob);
//        const a = document.createElement('a'); a.href = url; a.download = 'events.json'; a.click();
//   6. scp the file to the container for ingestion (per Decision 5 in the substrate handoff:
//      no pre-signed PUT — leaked URL is a corpus-poisoning attack surface).
//
// Batch sizing: ~80 sessions per browser invocation, cookie-expiry bounded. For the
// ~294-session dark-mass backfill, plan on ~4 batches.
//
// Throttle: 250ms between page requests. claude.ai has no documented rate limit on
// this endpoint; the throttle is operator-courtesy, not a hard requirement.

async function dumpEvents(sessionIds, options = {}) {
  const {pageSize = 500, throttleMs = 250, onProgress = null} = options;
  const out = {
    parser_version: 1,         // shared constant with lib/transcripts (see _PARSER_VERSION)
    dumped_at: new Date().toISOString(),
    sessions: {},
    errors: [],
  };

  for (let i = 0; i < sessionIds.length; i++) {
    const sid = sessionIds[i];
    if (onProgress) onProgress({sid, index: i, total: sessionIds.length});

    const sessionEvents = [];
    let afterId = 0;
    let pageNum = 0;

    while (true) {
      const url = `/v1/sessions/${sid}/events?after_id=${afterId}&limit=${pageSize}`;
      let response;
      try {
        response = await fetch(url, {credentials: 'include'});
      } catch (e) {
        out.errors.push({sid, page: pageNum, error: `fetch failed: ${e.message}`});
        break;
      }
      if (!response.ok) {
        out.errors.push({sid, page: pageNum, error: `HTTP ${response.status} ${response.statusText}`});
        break;
      }
      let body;
      try {
        body = await response.json();
      } catch (e) {
        out.errors.push({sid, page: pageNum, error: `JSON parse failed: ${e.message}`});
        break;
      }
      const events = body.events || [];
      if (events.length === 0) break;
      sessionEvents.push(...events);
      afterId = events[events.length - 1].id;
      pageNum += 1;
      if (events.length < pageSize) break;
      if (throttleMs > 0) await new Promise(r => setTimeout(r, throttleMs));
    }

    out.sessions[sid] = sessionEvents;
  }

  return out;
}

// Convenience: dump-and-download in one call. For interactive use.
async function dumpEventsToFile(sessionIds, filename = 'events.json', options = {}) {
  const data = await dumpEvents(sessionIds, {
    ...options,
    onProgress: ({sid, index, total}) => console.log(`[${index + 1}/${total}] ${sid}`),
  });
  const blob = new Blob([JSON.stringify(data, null, 2)], {type: 'application/json'});
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
  console.log(`Dumped ${Object.keys(data.sessions).length} sessions, ${data.errors.length} errors → ${filename}`);
  return data;
}
