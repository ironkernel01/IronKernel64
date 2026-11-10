CC      ?= gcc
CFLAGS  ?= -std=c11 -Wall -Wextra -Werror -pedantic -O2 -I..
TARGET  := menu.exe
OBJS    := main.o menu.o menu_callback_Test.o

.PHONY: all clean run demo

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $(OBJS)

main.o: main.c ../menu.h
	$(CC) $(CFLAGS) -c main.c

menu.o: ../menu.c ../menu.h
	$(CC) $(CFLAGS) -c ../menu.c

menu_callback_Test.o: menu_callback_Test.c ../menu.h
	$(CC) $(CFLAGS) -c menu_callback_Test.c

run: $(TARGET)
	./$(TARGET)

demo: $(TARGET)
	./$(TARGET) --demo

clean:
	rm -f $(OBJS) $(TARGET)
