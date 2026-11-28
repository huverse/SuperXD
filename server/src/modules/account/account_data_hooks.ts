import { Injectable } from '@nestjs/common';
import { EntityManager } from 'typeorm';

// 删除函数可以交回一个收尾：删文件这类回滚不了的事，等删账号的事务提交后才做（11-28 复核 F05：原来在事务里就删了文件，事务回滚时记录还在、文件已经没了）。
export type AfterCommit = () => Promise<void>;
export type AccountDataHook = (manager: EntityManager, accountIds: string[]) => Promise<void | AfterCommit>;

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

  // 返回各删除函数交回的收尾，由调用方在事务提交后执行。
  async run(manager: EntityManager, accountIds: string[]) {
    const after: AfterCommit[] = [];
    for (const hook of this.hooks) {
      const done = await hook(manager, accountIds);
      if (done) after.push(done);
    }
    return after;
  }

  async revoke(manager: EntityManager, accountIds: string[]) {
    for (const hook of this.revokes) await hook(manager, accountIds);
  }
}
