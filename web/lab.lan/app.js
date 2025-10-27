const { createApp, ref, onMounted } = Vue;

function hostFromUrl(u) {
  try { 
    return new URL(u).host; 
  } catch { 
    return ""; 
  }
}

async function probe(target, ms = 2500) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), ms);
  try {
    const res = await fetch(target, {
      method: "GET",
      cache: "no-store",
      redirect: "follow",
      signal: ctl.signal
    });
    return res.ok ? "ok" : "down";  // 2xx => ok; anything else => down
  } catch {
    return "down";                  // network/timeout => down
  } finally {
    clearTimeout(t);
  }
}

createApp({
  setup() {
    const links = ref([]);
    const lastChecked = ref("");

    async function load() {
      const res = await fetch("services.json", { cache: "no-cache" });
      const items = await res.json();
      links.value = items.map(x => ({
        ...x, host: hostFromUrl(x.href), statusClass: "loading"
      }));
      probeAll();
    }

    async function probeAll() {
      for (const item of links.value) item.statusClass = "loading";
      for (const item of links.value) {
        const target = item.probe || item.href;  // prefer same-origin probe
        item.statusClass = await probe(target);
      }
      lastChecked.value = new Date().toLocaleTimeString();
    }

    onMounted(load);
    return { links, lastChecked, probeAll };
  }
}).mount("#app");