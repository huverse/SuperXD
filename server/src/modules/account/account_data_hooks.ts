import { Injectable } from '@nestjs/common';
import { EntityManager } from 'typeorm';

export type AccountDataHook = (manager: EntityManager, accountIds: string[]) => Promise<void>;

// 账号下挂着的别的数据（积分、挑战）随账号一起删：那些模块依赖账号模块，在 onModuleInit 里登记自己的删除函数；
// 账号模块只在删账号的同一事务里挨个调用，不知道它们是什么（依赖只自上而下，不反向引用）。
@Injectable()
export class AccountDataHooks {
  private readonly hooks: AccountDataHook[] = [];

  register(hook: AccountDataHook) {
    this.hooks.push(hook);
  }

  async run(manager: EntityManager, accountIds: string[]) {
    for (const hook of this.hooks) await hook(manager, accountIds);
  }
}
