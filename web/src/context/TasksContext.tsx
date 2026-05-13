import { ReactNode, createContext, useCallback, useContext, useEffect, useMemo, useState } from 'react'
import { getTasks, getFollowUpdates, type TaskSummary, type FollowUpdatesResponse } from '../api'

type Value = {
  tasks: TaskSummary[]
  followUpdates: FollowUpdatesResponse | null
  refreshTasks: () => Promise<void>
  refreshFollowUpdates: (folder?: string) => Promise<void>
}

const Ctx = createContext<Value | null>(null)

export function TasksProvider({ children }: { children: ReactNode }) {
  const [tasks, setTasks] = useState<TaskSummary[]>([])
  const [followUpdates, setFollowUpdates] = useState<FollowUpdatesResponse | null>(null)

  const refreshTasks = useCallback(async () => {
    const r = await getTasks()
    setTasks(r.tasks ?? [])
  }, [])
  const refreshFollowUpdates = useCallback(async (folder?: string) => {
    setFollowUpdates(folder ? await getFollowUpdates({ folder }) : null)
  }, [])

  useEffect(() => { void refreshTasks() }, [refreshTasks])

  const value = useMemo(
    () => ({ tasks, followUpdates, refreshTasks, refreshFollowUpdates }),
    [tasks, followUpdates, refreshTasks, refreshFollowUpdates],
  )
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}

export function useTasks(): Value {
  const v = useContext(Ctx)
  if (!v) throw new Error('useTasks must be used within TasksProvider')
  return v
}
