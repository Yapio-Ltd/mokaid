/** Stripe Checkout is a full-page redirect (hosted Checkout blocks iframes). */
export function redirectToCheckout(url: string) {
  window.location.assign(url);
}
