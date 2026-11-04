/**
 * 直接监听，占用时才顺延下一个端口。
 *
 * 不做「探测—释放—再监听」：那中间存在被抢占的窗口，且会让错误被掩盖。
 *
 * @param {import('node:http').Server} server
 * @param {number} basePort
 * @param {number} [maxAttempts]
 * @returns {Promise<{ port: number, skipped: number[] }>}
 */
export function listenWithRetry(server, basePort, maxAttempts = 10) {
  return new Promise((resolve, reject) => {
    const skipped = [];
    let attempt = 0;

    const attemptListen = () => {
      const port = basePort + attempt;

      const onError = (err) => {
        server.removeListener('listening', onListening);
        if (err.code === 'EADDRINUSE' && attempt + 1 < maxAttempts) {
          skipped.push(port);
          attempt += 1;
          attemptListen();
          return;
        }
        if (err.code === 'EADDRINUSE') {
          const range = `${basePort}-${basePort + maxAttempts - 1}`;
          reject(new Error(maxAttempts === 1
            ? `端口 ${basePort} 已被占用，未启动服务（严格端口模式，不顺延）`
            : `端口 ${range} 全部被占用，未启动服务`));
          return;
        }
        reject(err);
      };

      const onListening = () => {
        server.removeListener('error', onError);
        resolve({ port: server.address().port, skipped });
      };

      server.once('error', onError);
      server.once('listening', onListening);
      server.listen(port, '127.0.0.1');
    };

    attemptListen();
  });
}
