import { Injectable } from '@nestjs/common';
import { EntityManager } from 'typeorm';

export type AccountDataHook = (manager: EntityManager, accountIds: string[]) => Promise<void>;

// 账号下挂着的别的数据（积分、挑战、解锁、诊断包认领、私信设备）随账号一起删：那些模块依赖账号模块，在 onModuleInit 里登记自己的删除函数；
// 账号模块只在删账号的同一事务里挨个调用，不知道它们是什么（依赖只自上而下，不反向引用）。
// 另一组是「收回」：凭恢复码重设、账号下别的设备都下线时，在同一事务里调用，能代表这个账号收发的东西（私信设备）由所属模块自己停掉。
@Injectable()
export class AccountDataHooks {
  private readonly hooks: AccountDataHook[] = [];
  private readonly revokes: AccountDataHook[] = [];

  register(hook: AccountDataHook) {
    this.hooks.push(hook);
  }

  registerRevoke(hook: AccountDataHook) {
    this.revokes.push(hook);
  }

  async run(manager: EntityManager, accountIds: string[]) {
    for (const hook of this.hooks) await hook(manager, accountIds);
  }

  async revoke(manager: EntityManager, accountIds: string[]) {
    for (const hook of this.revokes) await hook(manager, accountIds);
  }
}
