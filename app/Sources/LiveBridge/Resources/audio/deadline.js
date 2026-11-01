// A deadline for a promise that may never settle, such as a microphone request WebKit holds.

/**
 * Settles as `promise` does, or rejects with `late()` once `ms` have passed. A value that
 * arrives after the deadline goes to `onLate`, so that whatever it holds can be released.
 */
export function within(promise, ms, late, onLate = () => {}) {
  return new Promise((resolve, reject) => {
    let isLate = false;
    const timer = setTimeout(() => {
      isLate = true;
      reject(late());
    }, ms);
    promise.then(
      (value) => {
        clearTimeout(timer);
        if (isLate) onLate(value);
        else resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        if (!isLate) reject(error);
      },
    );
  });
}
