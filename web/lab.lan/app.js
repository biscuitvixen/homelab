const { createApp, ref, onMounted } = Vue;

console.log('[DEBUG] Vue app initialization started');

function hostFromUrl(u) {
  console.log('[DEBUG] hostFromUrl called with:', u);
  try { 
    const host = new URL(u).host;
    console.log('[DEBUG] hostFromUrl extracted host:', host);
    return host; 
  } catch (error) { 
    console.log('[DEBUG] hostFromUrl failed to parse URL:', u, 'Error:', error.message);
    return ""; 
  }
}

async function probe(target, ms = 2500) {
  console.log('[DEBUG] probe called with target:', target, 'timeout:', ms + 'ms');
  const ctl = new AbortController();
  const t = setTimeout(() => {
    console.log('[DEBUG] probe timeout reached for:', target);
    ctl.abort();
  }, ms);
  
  try {
    console.log('[DEBUG] Starting fetch request to:', target);
    const res = await fetch(target, {
      method: "GET",
      cache: "no-store",
      redirect: "follow",
      signal: ctl.signal
    });
    
    // Check for specific error status codes that indicate the service is down
    if (res.status >= 500 && res.status <= 599) {
      console.log('[DEBUG] probe response for', target, '- Status:', res.status, 'Result: down (5xx error)');
      return "down";
    }
    
    // Check for bad gateway, service unavailable, or gateway timeout
    if (res.status === 502 || res.status === 503 || res.status === 504) {
      console.log('[DEBUG] probe response for', target, '- Status:', res.status, 'Result: down (gateway error)');
      return "down";
    }
    
    // Additional check: if we get a 200 but the response is from Caddy error page
    // Check the Server header to see if it's a Caddy error response
    const server = res.headers.get('Server');
    if (res.status === 200 && server && server.toLowerCase().includes('caddy')) {
      // For probe endpoints, we should not get a Caddy-served page
      // This might indicate the upstream is down and Caddy is serving an error page
      console.log('[DEBUG] probe response for', target, '- Status:', res.status, 'but Server header indicates Caddy error page');
      return "down";
    }
    
    const status = res.ok ? "ok" : "down";
    console.log('[DEBUG] probe response for', target, '- Status:', res.status, 'Result:', status);
    return status;
  } catch (error) {
    console.log('[DEBUG] probe failed for', target, '- Error:', error.name, error.message);
    return "down";
  } finally {
    clearTimeout(t);
    console.log('[DEBUG] probe cleanup completed for:', target);
  }
}

createApp({
  setup() {
    console.log('[DEBUG] Vue app setup() called');
    const links = ref([]);
    const lastChecked = ref("");

    async function load() {
      console.log('[DEBUG] load() function called');
      try {
        console.log('[DEBUG] Fetching services.json...');
        const res = await fetch("services.json", { cache: "no-cache" });
        console.log('[DEBUG] services.json fetch response status:', res.status);
        
        const items = await res.json();
        console.log('[DEBUG] services.json parsed data:', items);
        console.log('[DEBUG] Number of services loaded:', items.length);
        
        links.value = items.map(x => {
          const host = hostFromUrl(x.href);
          const mappedItem = {
            ...x, 
            host: host, 
            statusClass: "loading"
          };
          console.log('[DEBUG] Mapped service item:', mappedItem);
          return mappedItem;
        });
        
        console.log('[DEBUG] All services mapped, starting probe...');
        probeAll();
      } catch (error) {
        console.error('[DEBUG] Error in load():', error);
      }
    }

    async function probeAll() {
      console.log('[DEBUG] probeAll() started');
      console.log('[DEBUG] Number of services to probe:', links.value.length);
      
      // Set all to loading state
      for (const item of links.value) {
        console.log('[DEBUG] Setting loading state for:', item.name || item.href);
        item.statusClass = "loading";
      }
      
      // Probe each service
      for (const item of links.value) {
        const target = item.probe || item.href;  // prefer same-origin probe
        console.log('[DEBUG] Probing service:', item.name || item.href, 'target:', target);
        
        const startTime = Date.now();
        item.statusClass = await probe(target);
        const endTime = Date.now();
        
        console.log('[DEBUG] Probe completed for:', item.name || item.href, 
                   'Result:', item.statusClass, 'Duration:', (endTime - startTime) + 'ms');
      }
      
      const timestamp = new Date().toLocaleTimeString();
      lastChecked.value = timestamp;
      console.log('[DEBUG] probeAll() completed at:', timestamp);
    }

    onMounted(() => {
      console.log('[DEBUG] Component mounted, calling load()');
      load();
    });
    
    console.log('[DEBUG] setup() returning reactive data and functions');
    return { links, lastChecked, probeAll };
  }
}).mount("#app");

console.log('[DEBUG] Vue app mounted to #app element');