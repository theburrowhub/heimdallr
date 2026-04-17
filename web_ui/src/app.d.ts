// See https://kit.svelte.dev/docs/types#app
declare global {
  namespace App {
    interface Locals {
      login: string | null;
    }
    // interface PageData {}
    // interface PageState {}
    // interface Platform {}
    interface Error {
      message: string;
    }
  }
}

export {};
