// Worker entry point. All logic lives in app.ts so tests can inject fetch/clock.
import { createWorker } from "./app";

export default createWorker();
