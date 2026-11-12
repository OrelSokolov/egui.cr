<template>
  <div class="card settings">
    <h1>{{ title }}</h1>
    <p v-if="subtitle" class="muted">{{ subtitle }}</p>
    <ul class="entries">
      <li v-for="(item, i) in items" :key="item.id">
        <span class="idx">{{ i }}</span>
        <span>{{ item.name }}</span>
      </li>
    </ul>
    <select v-model="filter">
      <option>All</option>
      <option>Active</option>
      <option>Done</option>
    </select>
    <button @click="save">Save</button>
  </div>
</template>

<style scoped>
.card { background: #ffffff; }
.muted { color: #888888; font-size: 13; }
.idx { color: #3584e4; }
</style>
