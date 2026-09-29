import { AI_ITEM_THRESHOLD, type Event } from "@aiexposure/types";

// Placeholder until 1.8 (Today and Trends views on mock events).
const sample: Event = {
  id: "01J9Z3K7Q8",
  started_at: "2026-09-27T19:01:05Z",
  dwell_ms: 12400,
  surface: "browser",
  app: "com.google.Chrome",
  domain: "instagram.com",
  media: "video",
  p_ai: 0.91,
  confidence: "high",
  signals: { provenance: null, visual: 0.88, context: 0.9 },
  category: "fitness",
  model_version: "vis-0.3.1",
};

const app = document.querySelector<HTMLElement>("#app");
if (app) {
  const heading = document.createElement("h1");
  heading.textContent = "AI Exposure";
  const note = document.createElement("p");
  const isAi = (sample.p_ai ?? 0) >= AI_ITEM_THRESHOLD;
  note.textContent = `Scaffold build. Sample item on ${sample.domain}: ${isAi ? "AI" : "not AI"}.`;
  app.append(heading, note);
}
