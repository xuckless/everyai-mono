import tkinter as tk
log = open('/work/events.txt', 'w', buffering=1)
root = tk.Tk(); root.title('Probe App'); root.geometry('400x300+40+40')
tk.Button(root, text='Press me', command=lambda: log.write('pressed\n')).pack(pady=10)
e = tk.Entry(root); e.pack(); e.bind('<Return>', lambda ev: log.write('entry=%s\n' % e.get()))
lb = tk.Listbox(root, height=4)
for i in range(30): lb.insert('end', 'item %d' % i)
lb.pack(); lb.bind('<<ListboxSelect>>', lambda ev: log.write('list=%s\n' % lb.get(lb.curselection()[0])))
root.mainloop()
