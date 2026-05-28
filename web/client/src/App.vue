<script setup lang="ts">
</script>

<template>
  <router-view v-slot="{ Component, route }">
    <keep-alive :max="10">
      <component :is="Component" :key="route.fullPath" />
    </keep-alive>
  </router-view>
</template>

<style scoped>
</style>
