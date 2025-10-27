const { createApp, ref, onMounted } = Vue;

function hostFromUrl(u) {
  try { 
    return new URL(u).host;
  } catch (error) { 
    return ""; 
  }
}

createApp({
  setup() {
    const links = ref([]);

    async function load() {
      try {
        const res = await fetch("services.json", { cache: "no-cache" });
        const items = await res.json();
        
        links.value = items.map(x => ({
          ...x, 
          host: hostFromUrl(x.href)
        }));
      } catch (error) {
        console.error('Error loading services:', error);
      }
    }

    onMounted(() => {
      load();
    });
    
    return { links };
  }
}).mount("#app");