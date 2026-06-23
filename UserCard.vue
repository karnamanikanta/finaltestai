<template>
  <div class="user-card">
    <h2>{{ user.name }}</h2>
    <p>{{ user.email }}</p>
  </div>
</template>

<script lang="ts">
import { defineComponent } from 'vue';

export default defineComponent({
  name: 'UserCard',
  props: {
    user: {
      type: Object,
      required: true
    }
  },
  computed: {
    displayName() {
      return this.user.name.toUpperCase();

  }
});
</script>

<style scoped>
.user-card {
  border: 1px solid #ccc;
  padding: 16px;
}
</style>
