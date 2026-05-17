<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { imageProxyUrl } from '@/services/api'

const props = withDefaults(defineProps<{
  src: string
  headers?: Record<string, string>
  alt?: string
  width?: string
  height?: string
  loading?: 'lazy' | 'eager'
  decoding?: 'async' | 'sync' | 'auto'
}>(), {
  alt: '',
  loading: 'lazy',
  decoding: 'async',
})

const imgRef = ref<HTMLElement>()
const isVisible = ref(false)
const isLoaded = ref(false)
const hasError = ref(false)

const proxiedSrc = computed(() => imageProxyUrl(props.src, props.headers))

let observer: IntersectionObserver | null = null

onMounted(() => {
  observer = new IntersectionObserver(([entry]) => {
    if (entry.isIntersecting) {
      isVisible.value = true
      observer?.disconnect()
    }
  }, { rootMargin: '100px' })
  if (imgRef.value) observer.observe(imgRef.value)
})

onUnmounted(() => observer?.disconnect())

function onLoad() { isLoaded.value = true }
function onError() { hasError.value = true }
</script>

<template>
  <div ref="imgRef" class="proxied-image" :style="{ width, height }">
    <img
      v-if="isVisible && !hasError"
      :src="proxiedSrc"
      :alt="alt"
      :loading="props.loading"
      :decoding="props.decoding"
      :class="{ loaded: isLoaded }"
      @load="onLoad"
      @error="onError"
    />
    <div v-if="!isLoaded && !hasError" class="placeholder">
      <van-loading size="24px" />
    </div>
    <div v-if="hasError" class="placeholder error">
      <van-icon name="photo-fail" size="32" color="#999" />
    </div>
  </div>
</template>

<style scoped>
.proxied-image {
  position: relative;
  overflow: hidden;
  background: #f5f5f5;
  transform: translateZ(0);
}
.proxied-image img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  opacity: 0;
  transition: opacity 0.25s ease;
  will-change: opacity;
}
.proxied-image img.loaded {
  opacity: 1;
}
.placeholder {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
}
</style>
