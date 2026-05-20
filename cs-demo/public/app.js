const state = {
  threadId: null,
  agents: [],
  currentAgent: "",
  context: {},
  events: [],
  messages: [],
  showSeatMap: false,
  selectedSeat: null,
  busy: false,
};

const elements = {
  agents: document.querySelector("#agents-list"),
  context: document.querySelector("#context-list"),
  events: document.querySelector("#runner-output"),
  messages: document.querySelector("#messages"),
  prompts: document.querySelector("#starter-prompts"),
  composer: document.querySelector("#composer"),
  input: document.querySelector("#message-input"),
  send: document.querySelector("#send-button"),
  reset: document.querySelector("#reset-button"),
  seatModal: document.querySelector("#seat-modal"),
  seatGrid: document.querySelector("#seat-map-grid"),
};

async function api(path, payload) {
  const options = payload
    ? {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      }
    : undefined;
  const response = await fetch(path, options);
  if (!response.ok) throw new Error(`${path} failed with ${response.status}`);
  return response.json();
}

function applySnapshot(snapshot) {
  state.threadId = snapshot.thread_id;
  state.agents = snapshot.agents || [];
  state.currentAgent = snapshot.current_agent || "";
  state.context = snapshot.context || {};
  state.events = normalizeEvents(snapshot.events || []);
  state.messages = snapshot.messages || [];
  state.showSeatMap = snapshot.show_seat_map === true;
  render();
}

function normalizeEvents(events) {
  const now = Date.now();
  const latestNonProgress = events
    .filter((event) => event.type !== "progress_update")
    .reduce((max, event) => Math.max(max, event.timestamp || 0), 0);

  return events.filter((event) => {
    if (event.type !== "progress_update") return true;
    if (latestNonProgress && event.timestamp < latestNonProgress) return false;
    return now - event.timestamp < 15000;
  });
}

function render() {
  renderAgents();
  renderContext();
  renderEvents();
  renderMessages();
  renderSeatMap();
  elements.send.disabled = state.busy;
  elements.input.disabled = state.busy;
}

function renderAgents() {
  const activeAgent = state.agents.find((agent) => agent.name === state.currentAgent);
  elements.agents.replaceChildren(
    ...state.agents.map((agent) => {
      const card = document.createElement("article");
      const available = agent.name === state.currentAgent || activeAgent?.handoffs?.includes(agent.name);
      card.className = `agent-card${agent.name === state.currentAgent ? " is-active" : ""}${available ? "" : " is-muted"}`;

      const title = document.createElement("h3");
      title.textContent = agent.name;
      const description = document.createElement("p");
      description.textContent = agent.description || "";
      card.append(title, description);

      if (agent.name === state.currentAgent) {
        const badge = document.createElement("span");
        badge.className = "badge";
        badge.textContent = "Active";
        card.append(badge);
      }
      return card;
    })
  );
}

function renderContext() {
  const entries = Object.entries(state.context);
  if (!entries.length) {
    const empty = document.createElement("div");
    empty.className = "empty-state";
    empty.textContent = "No context yet";
    elements.context.replaceChildren(empty);
    return;
  }

  elements.context.replaceChildren(
    ...entries.map(([key, value]) => {
      const item = document.createElement("div");
      item.className = "context-item";
      const dot = document.createElement("span");
      dot.className = "context-dot";
      const body = document.createElement("div");
      const label = document.createElement("div");
      label.className = "context-key";
      label.textContent = `${key}:`;
      const text = document.createElement("div");
      text.className = "context-value";
      text.textContent = formatValue(value);
      body.append(label, text);
      item.append(dot, body);
      return item;
    })
  );
}

function renderEvents() {
  const runnerEvents = state.events.filter((event) => event.type !== "message" && event.type !== "progress_update");
  if (!runnerEvents.length) {
    const empty = document.createElement("div");
    empty.className = "empty-state";
    empty.textContent = "No runner events yet";
    elements.events.replaceChildren(empty);
    return;
  }

  elements.events.replaceChildren(
    ...groupRunnerEvents(runnerEvents).map((group) => {
      const card = document.createElement("article");
      card.className = "event-card";
      const title = document.createElement("h3");
      title.textContent = group[0]?.agent || "Agent";
      card.append(title, ...group.map(renderEventLine));
      return card;
    })
  );
}

function renderEventLine(event) {
  const row = document.createElement("div");
  row.className = "event-line";
  const type = document.createElement("span");
  type.className = "event-type";
  type.textContent = formatEventType(event.type);
  const text = document.createElement("div");
  text.className = "event-text";
  text.textContent = eventText(event);
  row.append(type, text);
  return row;
}

function renderMessages() {
  if (!state.messages.length) {
    const greeting = document.createElement("div");
    greeting.className = "message assistant";
    const bubble = document.createElement("div");
    bubble.className = "message-bubble";
    bubble.textContent = "Hi! I'm your airline assistant. How can I help today?";
    greeting.append(bubble);
    elements.messages.replaceChildren(greeting);
  } else {
    elements.messages.replaceChildren(
      ...state.messages.map((message) => {
        const row = document.createElement("div");
        row.className = `message ${message.role}`;
        const bubble = document.createElement("div");
        bubble.className = "message-bubble";
        bubble.textContent = cleanAssistantText(message.content);
        row.append(bubble);
        return row;
      })
    );
  }

  elements.prompts.hidden = state.messages.length > 0;
  elements.messages.scrollTop = elements.messages.scrollHeight;
}

function renderSeatMap() {
  elements.seatModal.hidden = !state.showSeatMap;
  if (!state.showSeatMap || elements.seatGrid.childElementCount) return;

  const layout = [
    { title: "Business Class", rows: [1, 2, 3, 4], seats: ["A", "B", "C", "D"] },
    { title: "Economy Plus", rows: [5, 6, 7, 8], seats: ["A", "B", "C", "D", "E", "F"] },
    { title: "Economy", rows: Array.from({ length: 16 }, (_, index) => index + 9), seats: ["A", "B", "C", "D", "E", "F"] },
  ];
  elements.seatGrid.replaceChildren(...layout.map(renderSeatSection));
}

function renderSeatSection(section) {
  const root = document.createElement("section");
  root.className = "seat-section";
  const title = document.createElement("h3");
  title.textContent = section.title;
  root.append(title, ...section.rows.map((row) => renderSeatRow(row, section.seats)));
  return root;
}

function renderSeatRow(rowNumber, letters) {
  const row = document.createElement("div");
  row.className = "seat-row";
  const label = document.createElement("span");
  label.className = "row-number";
  label.textContent = rowNumber;
  const midpoint = Math.ceil(letters.length / 2);
  row.append(
    label,
    renderSeatGroup(rowNumber, letters.slice(0, midpoint)),
    document.createElement("span"),
    renderSeatGroup(rowNumber, letters.slice(midpoint))
  );
  return row;
}

function renderSeatGroup(rowNumber, letters) {
  const group = document.createElement("div");
  group.className = "seat-group";
  letters.forEach((letter) => {
    const seatNumber = `${rowNumber}${letter}`;
    const button = document.createElement("button");
    button.type = "button";
    button.className = seatClass(rowNumber, seatNumber);
    button.textContent = letter;
    button.title = `Seat ${seatNumber}`;
    button.disabled = occupiedSeats.has(seatNumber);
    button.addEventListener("click", () => chooseSeat(seatNumber));
    group.append(button);
  });
  return group;
}

async function sendMessage(text) {
  const message = text.trim();
  if (!message || state.busy) return;
  state.busy = true;
  render();

  try {
    const snapshot = await api("/api/message", { thread_id: state.threadId, message });
    elements.input.value = "";
    applySnapshot(snapshot);
  } catch (error) {
    showLocalError(error);
  } finally {
    state.busy = false;
    render();
    elements.input.focus();
  }
}

async function chooseSeat(seatNumber) {
  state.selectedSeat = seatNumber;
  state.busy = true;
  elements.seatModal.hidden = true;
  render();

  try {
    const snapshot = await api("/api/seat", { thread_id: state.threadId, seat: seatNumber });
    applySnapshot(snapshot);
  } catch (error) {
    showLocalError(error);
  } finally {
    state.busy = false;
    render();
  }
}

function groupRunnerEvents(events) {
  const groups = [];
  for (let index = 0; index < events.length; index += 1) {
    const current = events[index];
    if (current.type === "tool_call") {
      const group = [current];
      let nextIndex = index + 1;
      while (nextIndex < events.length && events[nextIndex].type === "tool_output" && events[nextIndex].agent === current.agent) {
        group.push(events[nextIndex]);
        nextIndex += 1;
      }
      groups.push(group);
      index = nextIndex - 1;
    } else {
      groups.push([current]);
    }
  }
  return groups;
}

function eventText(event) {
  if (event.type === "tool_call") {
    return `${event.content} - ${formatValue(event.metadata?.tool_args)}`;
  }
  if (event.type === "tool_output") {
    return formatValue(event.metadata?.tool_result ?? event.content);
  }
  if (event.type === "context_update") {
    return Object.entries(event.metadata?.changes || {})
      .map(([key, value]) => `${key}: ${formatValue(value)}`)
      .join(" · ");
  }
  return event.content || "";
}

function formatValue(value) {
  if (value === null || value === undefined || value === "") return "null";
  if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") return String(value);
  if (Array.isArray(value)) {
    if (!value.length) return "[]";
    if (value.every((item) => ["string", "number", "boolean"].includes(typeof item)) && value.length <= 3) {
      return value.join(", ");
    }
    return `${value.length} item${value.length === 1 ? "" : "s"}`;
  }
  return JSON.stringify(value);
}

function formatEventType(type) {
  return type.replace(/_/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function cleanAssistantText(text) {
  return String(text || "").replace("DISPLAY_SEAT_MAP", "Seat map opened.");
}

function showLocalError(error) {
  state.messages = [
    ...state.messages,
    { role: "assistant", content: `Local server error: ${error.message}`, timestamp: Date.now() },
  ];
}

const occupiedSeats = new Set([
  "1A", "2B", "3C", "5A", "5F", "7B", "7E", "9A", "9F", "10C", "10D",
  "12A", "12F", "14B", "14E", "16A", "16F", "18C", "18D", "20A", "20F",
  "22B", "22E", "24A", "24F",
]);
const exitRows = new Set([4, 16]);

function seatClass(rowNumber, seatNumber) {
  const classes = ["seat"];
  if (occupiedSeats.has(seatNumber)) classes.push("occupied");
  if (exitRows.has(rowNumber)) classes.push("exit");
  if (state.selectedSeat === seatNumber) classes.push("selected");
  return classes.join(" ");
}

elements.composer.addEventListener("submit", (event) => {
  event.preventDefault();
  sendMessage(elements.input.value);
});

elements.prompts.addEventListener("click", (event) => {
  const button = event.target.closest("[data-prompt]");
  if (button) sendMessage(button.dataset.prompt);
});

elements.reset.addEventListener("click", async () => {
  const snapshot = await api("/api/reset", { thread_id: state.threadId });
  state.selectedSeat = null;
  elements.seatGrid.replaceChildren();
  applySnapshot(snapshot);
});

document.addEventListener("click", (event) => {
  if (event.target.closest("[data-close-seat-map]")) {
    elements.seatModal.hidden = true;
  }
});

api("/api/bootstrap").then(applySnapshot).catch(showLocalError);
