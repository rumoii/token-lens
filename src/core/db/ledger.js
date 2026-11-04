import { openLedger } from './open.js';
import { LedgerQueries } from './read.js';
import { LedgerWriter } from './write.js';

/** 连接所有者：只在这里组装读写能力并关闭共享连接。 */
export class Ledger {
  #db;

  /** @type {LedgerQueries} */
  read;
  /** @type {LedgerWriter} */
  write;

  /** @param {string} dbPath */
  constructor(dbPath) {
    this.#db = openLedger(dbPath);
    try {
      this.read = new LedgerQueries(this.#db);
      this.write = new LedgerWriter(this.#db);
    } catch (error) {
      this.#db.close();
      throw error;
    }
  }

  close() {
    this.#db.close();
  }
}
